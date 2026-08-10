import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import Testing
@testable import PeekabooCore

@MainActor
struct RemoteCaptureGateOwnershipTests {
    @Test
    func `legacy remote observation delegates capture transaction gating to host`() {
        let client = PeekabooBridgeClient(
            socketPath: "/tmp/nonexistent-\(UUID().uuidString).sock",
            requestTimeoutSec: 1)
        let legacyObservation = RemotePeekabooServices(client: client, supportsDesktopObservation: false)
        let modernObservation = RemotePeekabooServices(client: client, supportsDesktopObservation: true)

        #expect(legacyObservation.desktopObservation is DesktopObservationService)
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
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1))
        let request = DesktopObservationRequest(
            target: .windowID(42),
            capture: DesktopCaptureOptions(
                roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
            output: DesktopObservationOutputOptions(
                path: outputURL.path,
                saveRawScreenshot: true))

        await #expect(throws: CaptureROIError.hostDidNotApplyROI) {
            _ = try await remote.observe(request)
        }
        let hostPath = try #require(observation.lastPath)
        #expect(hostPath != outputURL.path)
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
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1))
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
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1))
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
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1))

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
    }

    static let croppedData = Data("validated-roi".utf8)

    let mode: Mode
    private(set) var lastPath: String?

    init(mode: Mode) {
        self.mode = mode
    }

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        let path = try #require(request.output.path)
        self.lastPath = path
        try Self.croppedData.write(to: URL(fileURLWithPath: path), options: .atomic)
        guard self.mode == .valid else {
            return DesktopObservationResult(
                target: ResolvedObservationTarget(kind: .windowID(42)),
                capture: CaptureResult(
                    imageData: Self.croppedData,
                    savedPath: path,
                    metadata: CaptureMetadata(size: CGSize(width: 100, height: 80), mode: .window)),
                elements: nil,
                files: DesktopObservationFiles(rawScreenshotPath: path))
        }

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
            files: DesktopObservationFiles(rawScreenshotPath: path))
    }
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
