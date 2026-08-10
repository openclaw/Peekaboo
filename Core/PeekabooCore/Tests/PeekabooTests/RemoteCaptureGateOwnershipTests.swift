import CoreGraphics
import Foundation
import ImageIO
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation
import Testing
import UniformTypeIdentifiers
@testable import PeekabooCore

@MainActor
struct RemoteCaptureGateOwnershipTests {
    @Test
    func `remote ROI rejects a pre 1_20 host before transport`() async {
        let remote = RemoteDesktopObservationService(client: PeekabooBridgeClient(
            socketPath: "/tmp/nonexistent-roi-\(UUID().uuidString).sock",
            requestTimeoutSec: 1))

        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await remote.observe(DesktopObservationRequest(
                target: .windowID(42),
                capture: DesktopCaptureOptions(
                    roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10)))))
        }
        #expect(error?.code == .operationNotSupported)
    }

    @Test
    func `remote ROI rejects an exhausted overall deadline before transport`() async {
        let remote = RemoteDesktopObservationService(
            client: PeekabooBridgeClient(
                socketPath: "/tmp/nonexistent-roi-deadline-\(UUID().uuidString).sock",
                requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true)

        let error = await #expect(throws: CaptureError.self) {
            _ = try await remote.observe(DesktopObservationRequest(
                target: .windowID(42),
                capture: DesktopCaptureOptions(
                    roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
                timeout: DesktopObservationTimeouts(overall: 0)))
        }
        guard case let .detectionTimedOut(seconds) = error else {
            Issue.record("Expected detection timeout, got \(String(describing: error))")
            return
        }
        #expect(seconds == 0)
    }

    @Test
    func `legacy remote observation delegates capture transaction gating to host`() {
        let client = PeekabooBridgeClient(
            socketPath: "/tmp/nonexistent-\(UUID().uuidString).sock",
            requestTimeoutSec: 1)
        let legacyObservation = RemotePeekabooServices(client: client, supportsDesktopObservation: false)
        let modernObservation = RemotePeekabooServices(client: client, supportsDesktopObservation: true)

        #expect(!(legacyObservation.desktopObservation is RemoteDesktopObservationService))
        #expect(modernObservation.desktopObservation is RemoteDesktopObservationService)
        #expect(
            legacyObservation.screenCapture.captureTransactionGateOwner == CaptureTransactionGateOwner.service)
    }

    @Test
    func `legacy remote observation does not hold a client desktop lane across capture RPC`() async throws {
        let socketPath = "/tmp/peekaboo-remote-observation-lane-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.captureScreen],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: true,
                    postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = RemotePeekabooServices(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1),
            supportsDesktopObservation: false)

        let result = try await remote.desktopObservation.observe(DesktopObservationRequest(
            target: .screen(index: 0),
            detection: DesktopDetectionOptions(mode: .none)))

        #expect(result.capture.imageData == StubScreenCaptureService.sampleData)
        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await remote.desktopObservation.observe(DesktopObservationRequest(
                target: .windowID(42),
                capture: DesktopCaptureOptions(
                    roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10)))))
        }
        #expect(error?.code == .operationNotSupported)
        await host.stop()
    }

    @Test
    func `remote ROI fails closed when an old host ignores the crop`() async throws {
        let socketPath = "/tmp/peekaboo-remote-roi-\(UUID().uuidString).sock"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-remote-roi-public-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let observation = ROIFileObservationService(mode: .ignored)
        let server = PeekabooBridgeServer(
            services: StubServices(desktopObservation: observation),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: true,
                    postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = RemoteDesktopObservationService(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true)
        let request = DesktopObservationRequest(
            target: .windowID(42),
            capture: DesktopCaptureOptions(
                roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
            output: DesktopObservationOutputOptions(
                path: outputURL.path,
                saveRawScreenshot: true,
                saveSnapshot: true,
                snapshotID: "rejected-roi"))

        await #expect(throws: CaptureROIError.hostDidNotApplyROI) {
            _ = try await remote.observe(request)
        }
        let hostPath = try #require(observation.lastPath)
        #expect(hostPath != outputURL.path)
        #expect(observation.lastOutputOptions?.saveRawScreenshot == true)
        #expect(observation.lastOutputOptions?.saveSnapshot == false)
        #expect(!FileManager.default.fileExists(atPath: hostPath))
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        await host.stop()
    }

    @Test
    func `remote ROI publishes only after validating the quarantined artifact`() async throws {
        let socketPath = "/tmp/peekaboo-remote-valid-roi-\(UUID().uuidString).sock"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-remote-valid-roi-public-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let observation = ROIFileObservationService(mode: .valid)
        let server = PeekabooBridgeServer(
            services: StubServices(desktopObservation: observation),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: true,
                    postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = RemoteDesktopObservationService(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true)
        let request = DesktopObservationRequest(
            target: .windowID(42),
            capture: DesktopCaptureOptions(
                roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
            output: DesktopObservationOutputOptions(
                path: outputURL.path,
                saveRawScreenshot: true))

        let result = try await remote.observe(request)

        #expect(result.files.rawScreenshotPath == outputURL.path)
        #expect(try Data(contentsOf: outputURL) == ROIFileObservationService.croppedData)
        let hostPath = try #require(observation.lastPath)
        #expect(hostPath != outputURL.path)
        #expect(!FileManager.default.fileExists(atPath: hostPath))
        await host.stop()
    }

    @Test
    func `remote ROI resolves an existing output directory without replacing it`() async throws {
        let socketPath = "/tmp/peekaboo-remote-directory-roi-\(UUID().uuidString).sock"
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-remote-directory-roi-\(UUID().uuidString)", isDirectory: true)
        let markerURL = outputDirectory.appendingPathComponent("marker.txt")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: false)
        try Data("preserve-directory".utf8).write(to: markerURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let observation = ROIFileObservationService(mode: .valid)
        let server = PeekabooBridgeServer(
            services: StubServices(desktopObservation: observation),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: true,
                    postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = RemoteDesktopObservationService(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true)

        let result = try await remote.observe(DesktopObservationRequest(
            target: .windowID(42),
            capture: DesktopCaptureOptions(
                roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
            output: DesktopObservationOutputOptions(
                path: outputDirectory.path,
                saveRawScreenshot: true)))

        let rawPath = try #require(result.files.rawScreenshotPath)
        #expect(URL(fileURLWithPath: rawPath).deletingLastPathComponent() == outputDirectory)
        #expect(try Data(contentsOf: markerURL) == Data("preserve-directory".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: rawPath)) == ROIFileObservationService.croppedData)
        await host.stop()
    }

    @Test
    func `remote ROI publishes its snapshot only after client validation`() async throws {
        let socketPath = "/tmp/peekaboo-remote-snapshot-roi-\(UUID().uuidString).sock"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-remote-snapshot-roi-public-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }
        let snapshotID = "validated-roi-\(UUID().uuidString)"
        let snapshots = InMemorySnapshotManager(options: .init(copyArtifactsOnStore: true))
        let observation = ROIFileObservationService(mode: .valid)
        let server = PeekabooBridgeServer(
            services: StubServices(snapshots: snapshots, desktopObservation: observation),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation, .storeScreenshot],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: true,
                    postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = RemoteDesktopObservationService(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true)

        _ = try await remote.observe(DesktopObservationRequest(
            target: .windowID(42),
            capture: DesktopCaptureOptions(
                roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
            output: DesktopObservationOutputOptions(
                path: outputURL.path,
                saveSnapshot: true,
                snapshotID: snapshotID)))

        #expect(observation.lastOutputOptions?.saveSnapshot == false)
        let snapshot = try #require(try await snapshots.getUIAutomationSnapshot(snapshotId: snapshotID))
        #expect(snapshot.captureCoordinateContext?.viewport?.requestedWindowRelativeBounds ==
            CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(snapshot.windowID == 42)
        #expect(snapshot.windowMutationIdentity?.windowID == 42)
        let storedScreenshotPath = try #require(snapshot.screenshotPath)
        #expect(storedScreenshotPath.contains("/peekaboo-see/"))
        try ROIFileObservationService.fullWindowData.write(to: outputURL, options: .atomic)
        #expect(try Data(contentsOf: URL(fileURLWithPath: storedScreenshotPath)) ==
            ROIFileObservationService.croppedData)
        try await snapshots.cleanSnapshot(snapshotId: snapshotID)
        #expect(!FileManager.default.fileExists(atPath: storedScreenshotPath))
        await host.stop()
    }

    @Test
    func `remote ROI rejects full window pixels behind a valid crop receipt`() async throws {
        let socketPath = "/tmp/peekaboo-remote-mismatched-roi-\(UUID().uuidString).sock"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-remote-mismatched-roi-public-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let observation = ROIFileObservationService(mode: .mismatchedArtifact)
        let server = PeekabooBridgeServer(
            services: StubServices(desktopObservation: observation),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: true,
                    postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = RemoteDesktopObservationService(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true)

        await #expect(throws: CaptureROIError.hostDidNotApplyROI) {
            _ = try await remote.observe(DesktopObservationRequest(
                target: .windowID(42),
                capture: DesktopCaptureOptions(
                    roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
                output: DesktopObservationOutputOptions(
                    path: outputURL.path,
                    saveRawScreenshot: true)))
        }
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        await host.stop()
    }

    @Test
    func `remote ROI validates every artifact before publishing any output`() async throws {
        let socketPath = "/tmp/peekaboo-remote-mismatched-annotated-roi-\(UUID().uuidString).sock"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-remote-mismatched-annotated-roi-public-\(UUID().uuidString).png")
        let annotatedURL = URL(fileURLWithPath: ObservationOutputWriter.annotatedScreenshotPath(
            forRawScreenshotPath: outputURL.path))
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: annotatedURL)
        }
        let existingData = Data("existing-public-output".utf8)
        try existingData.write(to: outputURL, options: .atomic)
        let observation = ROIFileObservationService(mode: .mismatchedAnnotatedArtifact)
        let server = PeekabooBridgeServer(
            services: StubServices(desktopObservation: observation),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: true,
                    postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = RemoteDesktopObservationService(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true)

        await #expect(throws: CaptureROIError.hostDidNotApplyROI) {
            _ = try await remote.observe(DesktopObservationRequest(
                target: .windowID(42),
                capture: DesktopCaptureOptions(
                    roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
                output: DesktopObservationOutputOptions(
                    path: outputURL.path,
                    saveRawScreenshot: true,
                    saveAnnotatedScreenshot: true)))
        }
        #expect(try Data(contentsOf: outputURL) == existingData)
        #expect(!FileManager.default.fileExists(atPath: annotatedURL.path))
        await host.stop()
    }

    @Test
    func `remote ROI never replaces an annotated destination directory`() async throws {
        let socketPath = "/tmp/peekaboo-remote-annotated-directory-roi-\(UUID().uuidString).sock"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-remote-annotated-directory-roi-\(UUID().uuidString).png")
        let annotatedURL = URL(fileURLWithPath: ObservationOutputWriter.annotatedScreenshotPath(
            forRawScreenshotPath: outputURL.path), isDirectory: true)
        let markerURL = annotatedURL.appendingPathComponent("marker.txt")
        try FileManager.default.createDirectory(at: annotatedURL, withIntermediateDirectories: false)
        try Data("preserve-annotated-directory".utf8).write(to: markerURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: annotatedURL)
        }
        let observation = ROIFileObservationService(mode: .valid)
        let server = PeekabooBridgeServer(
            services: StubServices(desktopObservation: observation),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: true,
                    postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = RemoteDesktopObservationService(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true)

        await #expect(throws: CaptureROIError.invalidSourceImage) {
            _ = try await remote.observe(DesktopObservationRequest(
                target: .windowID(42),
                capture: DesktopCaptureOptions(
                    roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
                output: DesktopObservationOutputOptions(
                    path: outputURL.path,
                    saveRawScreenshot: true,
                    saveAnnotatedScreenshot: true)))
        }
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        #expect(try Data(contentsOf: markerURL) == Data("preserve-annotated-directory".utf8))
        await host.stop()
    }

    @Test
    func `remote ROI refuses a self consistent crop from the wrong exact window`() async throws {
        let socketPath = "/tmp/peekaboo-remote-wrong-roi-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: StubServices(desktopObservation: WrongWindowROIObservationService()),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: true,
                    postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = RemoteDesktopObservationService(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true)
        let request = DesktopObservationRequest(
            target: .windowID(42),
            capture: DesktopCaptureOptions(
                roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))))

        await #expect(throws: CaptureROIError.hostDidNotApplyROI) {
            _ = try await remote.observe(request)
        }
        await host.stop()
    }

    @Test
    func `remote ROI preserves typed host validation errors`() async throws {
        let socketPath = "/tmp/peekaboo-remote-roi-error-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: StubServices(desktopObservation: FailingROIObservationService(error: .outOfBounds)),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: true,
                    postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = RemoteDesktopObservationService(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true)

        let error = await #expect(throws: CaptureROIError.self) {
            _ = try await remote.observe(DesktopObservationRequest(
                target: .windowID(42),
                capture: DesktopCaptureOptions(
                    roi: CaptureRegionOfInterest(bounds: CGRect(x: 90, y: 0, width: 20, height: 10)))))
        }
        #expect(error == .outOfBounds)
        await host.stop()
    }
}

@MainActor
private final class FailingROIObservationService: DesktopObservationServiceProtocol {
    let error: CaptureROIError

    init(error: CaptureROIError) {
        self.error = error
    }

    func observe(_: DesktopObservationRequest) async throws -> DesktopObservationResult {
        throw self.error
    }
}

@MainActor
private final class ROIFileObservationService: DesktopObservationServiceProtocol {
    enum Mode {
        case valid
        case ignored
        case mismatchedArtifact
        case mismatchedAnnotatedArtifact
    }

    static let croppedData = makeROITestImageData(width: 10, height: 10, red: 0.2, green: 0.7, blue: 0.3)
    static let fullWindowData = makeROITestImageData(width: 100, height: 80, red: 0.8, green: 0.2, blue: 0.1)

    let mode: Mode
    private(set) var lastPath: String?
    private(set) var lastOutputOptions: DesktopObservationOutputOptions?

    init(mode: Mode) {
        self.mode = mode
    }

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        let path = try #require(request.output.path)
        self.lastPath = path
        self.lastOutputOptions = request.output
        let artifactData = self.mode == .ignored || self.mode == .mismatchedArtifact
            ? Self.fullWindowData
            : Self.croppedData
        try artifactData.write(to: URL(fileURLWithPath: path), options: .atomic)
        if request.output.saveAnnotatedScreenshot {
            let annotatedPath = ObservationOutputWriter.annotatedScreenshotPath(forRawScreenshotPath: path)
            let annotatedData = self.mode == .mismatchedAnnotatedArtifact
                ? Self.fullWindowData
                : Self.croppedData
            try annotatedData.write(to: URL(fileURLWithPath: annotatedPath), options: .atomic)
        }
        guard self.mode != .ignored else {
            return DesktopObservationResult(
                target: ResolvedObservationTarget(kind: .windowID(42)),
                capture: CaptureResult(
                    imageData: Self.croppedData,
                    savedPath: path,
                    metadata: CaptureMetadata(size: CGSize(width: 100, height: 80), mode: .window)),
                elements: nil,
                files: DesktopObservationFiles(rawScreenshotPath: path))
        }

        return try self.validResult(for: request, path: path)
    }

    private func validResult(for request: DesktopObservationRequest, path: String) throws -> DesktopObservationResult {
        let bounds = CGRect(x: 100, y: 200, width: 100, height: 80)
        let roi = try #require(request.capture.roi)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 456,
            capturedBounds: bounds)
        return DesktopObservationResult(
            target: ResolvedObservationTarget(
                kind: .windowID(42),
                app: ApplicationIdentity(
                    processIdentifier: 123,
                    processStartIdentity: 456,
                    bundleIdentifier: "test.valid-roi",
                    name: "ROI Fixture"),
                window: WindowIdentity(windowID: 42, title: "ROI", bounds: bounds, index: 0),
                bounds: bounds,
                detectionContext: WindowContext(
                    applicationName: "ROI Fixture",
                    applicationBundleId: "test.valid-roi",
                    applicationProcessId: 123,
                    windowTitle: "ROI",
                    windowID: 42,
                    windowBounds: bounds,
                    windowMutationIdentity: identity)),
            capture: CaptureResult(
                imageData: Self.croppedData,
                savedPath: path,
                metadata: CaptureMetadata(
                    size: roi.bounds.size,
                    mode: .window,
                    applicationInfo: ServiceApplicationInfo(
                        processIdentifier: 123,
                        processStartIdentity: 456,
                        bundleIdentifier: "test.valid-roi",
                        name: "ROI Fixture"),
                    windowInfo: ServiceWindowInfo(
                        windowID: 42,
                        title: "ROI",
                        bounds: bounds,
                        mutationIdentity: identity),
                    viewport: CaptureViewport(
                        sourceLogicalBounds: bounds,
                        requestedWindowRelativeBounds: roi.bounds,
                        deliveredWindowRelativeBounds: roi.bounds,
                        logicalBounds: CGRect(
                            x: bounds.minX + roi.bounds.minX,
                            y: bounds.minY + roi.bounds.minY,
                            width: roi.bounds.width,
                            height: roi.bounds.height),
                        sourceImageSize: bounds.size))),
            elements: nil,
            files: DesktopObservationFiles(
                rawScreenshotPath: path,
                annotatedScreenshotPath: request.output.saveAnnotatedScreenshot
                    ? ObservationOutputWriter.annotatedScreenshotPath(forRawScreenshotPath: path)
                    : nil))
    }
}

private func makeROITestImageData(
    width: Int,
    height: Int,
    red: CGFloat,
    green: CGFloat,
    blue: CGFloat) -> Data
{
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let image = {
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }()
    else {
        preconditionFailure("Failed to create ROI test image")
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil)
    else {
        preconditionFailure("Failed to create ROI test image destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        preconditionFailure("Failed to encode ROI test image")
    }
    return data as Data
}

@MainActor
private final class WrongWindowROIObservationService: DesktopObservationServiceProtocol {
    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        let windowID = 43
        let bounds = CGRect(x: 100, y: 200, width: 100, height: 80)
        let roi = try #require(request.capture.roi)
        let identity = WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 456,
            capturedBounds: bounds)
        return DesktopObservationResult(
            target: ResolvedObservationTarget(
                kind: .windowID(CGWindowID(windowID)),
                app: ApplicationIdentity(
                    processIdentifier: 123,
                    processStartIdentity: 456,
                    bundleIdentifier: "test.wrong-window",
                    name: "Wrong Window"),
                window: WindowIdentity(windowID: windowID, title: "Wrong", bounds: bounds, index: 0),
                bounds: bounds,
                detectionContext: WindowContext(
                    applicationName: "Wrong Window",
                    applicationBundleId: "test.wrong-window",
                    applicationProcessId: 123,
                    windowTitle: "Wrong",
                    windowID: windowID,
                    windowBounds: bounds,
                    windowMutationIdentity: identity)),
            capture: CaptureResult(
                imageData: Data(),
                metadata: CaptureMetadata(
                    size: roi.bounds.size,
                    mode: .window,
                    applicationInfo: ServiceApplicationInfo(
                        processIdentifier: 123,
                        processStartIdentity: 456,
                        bundleIdentifier: "test.wrong-window",
                        name: "Wrong Window"),
                    windowInfo: ServiceWindowInfo(
                        windowID: windowID,
                        title: "Wrong",
                        bounds: bounds,
                        mutationIdentity: identity),
                    viewport: CaptureViewport(
                        sourceLogicalBounds: bounds,
                        requestedWindowRelativeBounds: roi.bounds,
                        deliveredWindowRelativeBounds: roi.bounds,
                        logicalBounds: CGRect(
                            x: bounds.minX + roi.bounds.minX,
                            y: bounds.minY + roi.bounds.minY,
                            width: roi.bounds.width,
                            height: roi.bounds.height),
                        sourceImageSize: bounds.size))),
            elements: nil)
    }
}
