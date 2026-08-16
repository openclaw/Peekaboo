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
    private static let roiFixtureBounds = CGRect(x: 100, y: 200, width: 100, height: 80)
    private static let receiptlessProtocolVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.remote-capture-tests",
        teamIdentifier: nil,
        processIdentifier: getpid(),
        hostname: nil)

    private func makeNegotiatedClient(
        socketPath: String,
        requestTimeoutSec: TimeInterval,
        protocolVersion: PeekabooBridgeProtocolVersion = PeekabooBridgeConstants.protocolVersion) async throws
        -> PeekabooBridgeClient
    {
        let client = TrustedBridgeClientFixture.make(
            socketPath: socketPath,
            requestTimeoutSec: requestTimeoutSec)
        let handshake = try await client.handshake(
            client: Self.clientIdentity,
            protocolVersion: protocolVersion)
        #expect(handshake.negotiatedVersion == protocolVersion)
        if protocolVersion >= PeekabooBridgeConstants.attestedOperationReceiptVersion {
            #expect(handshake.operationAttestation != nil)
            #expect(handshake.operationSessionAttestation != nil)
        } else {
            #expect(handshake.operationAttestation == nil)
            #expect(handshake.operationSessionAttestation == nil)
        }
        return client
    }

    private func makeROIServer(
        services: any PeekabooBridgeServiceProviding,
        allowedOperations: Set<PeekabooBridgeOperation> = [.desktopObservation]) -> PeekabooBridgeServer
    {
        let fixtureBounds = Self.roiFixtureBounds
        return PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: allowedOperations,
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: true,
                    postEvent: true)
            },
            windowOwnerProcessIdentifierProvider: { windowID in
                windowID == 42 ? 123 : nil
            },
            windowBoundsProvider: { windowID in
                windowID == 42 ? fixtureBounds : nil
            },
            processStartIdentityProvider: { processIdentifier in
                processIdentifier == 123 ? 456 : nil
            })
    }
}

extension RemoteCaptureGateOwnershipTests {
    @Test
    func `remote ROI rejects a pre 1_21 host before transport`() async {
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
    func `remote OCR rejects a host without capability before transport`() async {
        let remote = RemoteDesktopObservationService(client: PeekabooBridgeClient(
            socketPath: "/tmp/nonexistent-ocr-\(UUID().uuidString).sock",
            requestTimeoutSec: 1))

        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await remote.observe(DesktopObservationRequest(
                target: .screen(index: 0),
                detection: DesktopDetectionOptions(mode: .accessibilityAndOCR)))
        }

        #expect(error?.code == .operationNotSupported)
        #expect(error?.message.contains(PeekabooBridgeHostCapability.desktopObservationOCR) == true)
        #expect(error?.message.contains("--no-remote") == true)
    }

    @Test(arguments: [CaptureEnginePreference.modern, .legacy])
    func `remote capture engine rejects a host without capability before transport`(
        engine: CaptureEnginePreference) async
    {
        let remote = RemoteDesktopObservationService(client: PeekabooBridgeClient(
            socketPath: "/tmp/nonexistent-capture-engine-\(UUID().uuidString).sock",
            requestTimeoutSec: 1))

        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await remote.observe(DesktopObservationRequest(
                target: .screen(index: 0),
                capture: DesktopCaptureOptions(engine: engine),
                detection: DesktopDetectionOptions(mode: .none)))
        }

        #expect(error?.code == .operationNotSupported)
        #expect(error?.message.contains(PeekabooBridgeHostCapability.desktopObservationCaptureEngine) == true)
        #expect(error?.message.contains("--no-remote") == true)
    }

    @Test
    func `legacy remote observation rejects capture engine before local fallback transport`() async {
        let remote = RemotePeekabooServices(client: PeekabooBridgeClient(
            socketPath: "/tmp/nonexistent-legacy-capture-engine-\(UUID().uuidString).sock",
            requestTimeoutSec: 1))

        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await remote.desktopObservation.observe(DesktopObservationRequest(
                target: .screen(index: 0),
                capture: DesktopCaptureOptions(engine: .modern),
                detection: DesktopDetectionOptions(mode: .none)))
        }

        #expect(error?.code == .operationNotSupported)
        #expect(error?.message.contains(PeekabooBridgeHostCapability.desktopObservationCaptureEngine) == true)
    }

    @Test
    func `legacy remote observation rejects OCR before local fallback capture transport`() async {
        let remote = RemotePeekabooServices(client: PeekabooBridgeClient(
            socketPath: "/tmp/nonexistent-legacy-ocr-\(UUID().uuidString).sock",
            requestTimeoutSec: 1))

        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await remote.desktopObservation.observe(DesktopObservationRequest(
                target: .screen(index: 0),
                detection: DesktopDetectionOptions(mode: .accessibilityAndOCR)))
        }

        #expect(error?.code == .operationNotSupported)
        #expect(error?.message.contains(PeekabooBridgeHostCapability.desktopObservationOCR) == true)
    }

    @Test
    func `remote OCR gates the new mode but preserves legacy preferred OCR`() async throws {
        let socketPath = "/tmp/peekaboo-remote-capable-ocr-\(UUID().uuidString).sock"
        let observation = PathlessTrackingObservationService()
        let services = StubServices(desktopObservation: observation)
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: false,
                    postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = try await self.makeNegotiatedClient(
            socketPath: socketPath,
            requestTimeoutSec: 1,
            protocolVersion: Self.receiptlessProtocolVersion)
        let remote = RemoteDesktopObservationService(
            client: client,
            supportsDesktopObservationOCR: true)
        let explicitOCRRequest = DesktopObservationRequest(
            target: .screen(index: 0),
            detection: DesktopDetectionOptions(mode: .accessibilityAndOCR))

        _ = try await remote.observe(explicitOCRRequest)

        #expect(observation.lastRequest == explicitOCRRequest)

        let legacyRemote = RemoteDesktopObservationService(
            client: client,
            supportsDesktopObservationOCR: false)
        let preferredOCRRequest = DesktopObservationRequest(
            target: .menubarPopover(hints: [], openIfNeeded: nil),
            detection: DesktopDetectionOptions(mode: .none, preferOCR: true))

        _ = try await legacyRemote.observe(preferredOCRRequest)

        #expect(observation.lastRequest == preferredOCRRequest)

        let engineRemote = RemoteDesktopObservationService(
            client: client,
            supportsDesktopObservationCaptureEngine: true)
        let engineRequest = DesktopObservationRequest(
            target: .screen(index: 0),
            capture: DesktopCaptureOptions(engine: .modern),
            detection: DesktopDetectionOptions(mode: .none))

        _ = try await engineRemote.observe(engineRequest)

        #expect(observation.lastRequest == engineRequest)
        await host.stop()
    }

    @Test
    func `remote combined observation rejects legacy empty exact AX while screenshot only succeeds`() async throws {
        let socketPath = "/tmp/peekaboo-remote-empty-evidence-\(UUID().uuidString).sock"
        let observation = LegacyEmptyExactObservationService()
        let server = self.makeROIServer(services: StubServices(desktopObservation: observation))
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 5)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = try await self.makeNegotiatedClient(
            socketPath: socketPath,
            requestTimeoutSec: 5)
        let remote = RemoteDesktopObservationService(client: client)

        let error = await #expect(throws: PeekabooError.self) {
            _ = try await remote.observe(DesktopObservationRequest(
                target: .windowID(42),
                detection: DesktopDetectionOptions(mode: .accessibility)))
        }
        guard case .accessibilityIncomplete? = error else {
            Issue.record("Expected accessibilityIncomplete, got \(String(describing: error))")
            return
        }
        #expect(error?.localizedDescription.contains("Exact window 42") == true)

        let screenshotOnly = try await remote.observe(DesktopObservationRequest(
            target: .windowID(42),
            detection: DesktopDetectionOptions(mode: .none)))
        #expect(screenshotOnly.elements == nil)
        #expect(await client.lastOperationReceipt()?.payload.operation == .desktopObservation)
        #expect(observation.requests.map(\.detection.mode) == [.accessibility, .none])
        await host.stop()
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
        let client = try await self.makeNegotiatedClient(
            socketPath: socketPath,
            requestTimeoutSec: 1,
            protocolVersion: Self.receiptlessProtocolVersion)
        let remote = RemotePeekabooServices(
            client: client,
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
        let server = self.makeROIServer(services: StubServices(desktopObservation: observation))
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = try await RemoteDesktopObservationService(
            client: self.makeNegotiatedClient(
                socketPath: socketPath,
                requestTimeoutSec: 1,
                protocolVersion: Self.receiptlessProtocolVersion),
            supportsExactWindowROIObservation: true)
        let request = DesktopObservationRequest(
            target: .windowID(42),
            capture: DesktopCaptureOptions(
                roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
            detection: DesktopDetectionOptions(mode: .none),
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
        let server = self.makeROIServer(services: StubServices(desktopObservation: observation))
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = try await RemoteDesktopObservationService(
            client: self.makeNegotiatedClient(
                socketPath: socketPath,
                requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true)
        let request = DesktopObservationRequest(
            target: .windowID(42),
            capture: DesktopCaptureOptions(
                roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
            detection: DesktopDetectionOptions(mode: .none),
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
    func `remote ROI returns validated artifact bytes instead of untrusted in memory pixels`() async throws {
        let socketPath = "/tmp/peekaboo-remote-memory-roi-\(UUID().uuidString).sock"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-remote-memory-roi-public-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let observation = ROIFileObservationService(mode: .mismatchedCaptureData)
        let server = self.makeROIServer(services: StubServices(desktopObservation: observation))
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = try await RemoteDesktopObservationService(
            client: self.makeNegotiatedClient(
                socketPath: socketPath,
                requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true)

        let result = try await remote.observe(DesktopObservationRequest(
            target: .windowID(42),
            capture: DesktopCaptureOptions(
                roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
            detection: DesktopDetectionOptions(mode: .none),
            output: DesktopObservationOutputOptions(
                path: outputURL.path,
                saveRawScreenshot: true)))

        #expect(result.capture.imageData == ROIFileObservationService.croppedData)
        #expect(try Data(contentsOf: outputURL) == ROIFileObservationService.croppedData)
        #expect(result.capture.imageData != ROIFileObservationService.fullWindowData)
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
        let server = self.makeROIServer(services: StubServices(desktopObservation: observation))
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = try await RemoteDesktopObservationService(
            client: self.makeNegotiatedClient(
                socketPath: socketPath,
                requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true)

        let result = try await remote.observe(DesktopObservationRequest(
            target: .windowID(42),
            capture: DesktopCaptureOptions(
                roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
            detection: DesktopDetectionOptions(mode: .none),
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
        let observation = ROIFileObservationService(mode: .validWithElements)
        let server = self.makeROIServer(
            services: StubServices(snapshots: snapshots, desktopObservation: observation),
            allowedOperations: [
                .desktopObservation,
                .storeObservationSnapshot,
                .storeScreenshot,
                .storeDetectionResult,
            ])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = try await RemoteDesktopObservationService(
            client: self.makeNegotiatedClient(
                socketPath: socketPath,
                requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true)

        let result = try await remote.observe(DesktopObservationRequest(
            target: .windowID(42),
            capture: DesktopCaptureOptions(
                roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
            output: DesktopObservationOutputOptions(
                path: outputURL.path,
                saveSnapshot: true,
                snapshotID: snapshotID)))

        #expect(observation.lastOutputOptions?.saveSnapshot == false)
        #expect(result.files.rawScreenshotPath == nil)
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        let snapshot = try #require(try await snapshots.getUIAutomationSnapshot(snapshotId: snapshotID))
        #expect(snapshot.captureCoordinateContext?.viewport?.requestedWindowRelativeBounds ==
            CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(snapshot.windowID == 42)
        #expect(snapshot.windowMutationIdentity?.windowID == 42)
        let storedScreenshotPath = try #require(snapshot.screenshotPath)
        #expect(storedScreenshotPath.contains("/peekaboo-see/"))
        let storedDetection = try #require(try await snapshots.getDetectionResult(snapshotId: snapshotID))
        #expect(storedDetection.screenshotPath == storedScreenshotPath)
        #expect(FileManager.default.fileExists(atPath: storedDetection.screenshotPath))
        try ROIFileObservationService.fullWindowData.write(to: outputURL, options: .atomic)
        #expect(try Data(contentsOf: URL(fileURLWithPath: storedScreenshotPath)) ==
            ROIFileObservationService.croppedData)
        try await snapshots.cleanSnapshot(snapshotId: snapshotID)
        #expect(!FileManager.default.fileExists(atPath: storedScreenshotPath))
        await host.stop()
    }

    @Test
    func `remote ROI keeps public output untouched when snapshot publication fails`() async throws {
        let socketPath = "/tmp/peekaboo-remote-rollback-roi-\(UUID().uuidString).sock"
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-remote-rollback-roi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let outputURL = outputDirectory.appendingPathComponent("existing.png")
        let existingData = Data("existing-public-output".utf8)
        try existingData.write(to: outputURL, options: .atomic)
        let snapshotID = "rollback-roi-\(UUID().uuidString)"
        let snapshots = InMemorySnapshotManager(options: .init(copyArtifactsOnStore: true))
        let observation = ROIFileObservationService(mode: .validWithElements)
        let server = self.makeROIServer(
            services: StubServices(snapshots: snapshots, desktopObservation: observation),
            allowedOperations: [.desktopObservation])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = try await RemoteDesktopObservationService(
            client: self.makeNegotiatedClient(
                socketPath: socketPath,
                requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true)

        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await remote.observe(DesktopObservationRequest(
                target: .windowID(42),
                capture: DesktopCaptureOptions(
                    roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
                output: DesktopObservationOutputOptions(
                    path: outputURL.path,
                    saveRawScreenshot: true,
                    saveSnapshot: true,
                    snapshotID: snapshotID)))
        }

        #expect(error?.code == .operationNotSupported)
        #expect(try Data(contentsOf: outputURL) == existingData)
        #expect(try await snapshots.getUIAutomationSnapshot(snapshotId: snapshotID) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path) == ["existing.png"])
        await host.stop()
    }

    @Test
    func `remote ROI reports snapshot only success when public artifact installation conflicts`() async throws {
        let socketPath = "/tmp/peekaboo-remote-snapshot-only-roi-\(UUID().uuidString).sock"
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-remote-snapshot-only-roi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let outputURL = outputDirectory.appendingPathComponent("conflicted.png")
        try Data("replace-before-install".utf8).write(to: outputURL, options: .atomic)
        let snapshotID = "snapshot-only-roi-\(UUID().uuidString)"
        let snapshots = InMemorySnapshotManager(options: .init(copyArtifactsOnStore: true))
        let observation = ROIFileObservationService(mode: .validWithElements)
        let server = self.makeROIServer(
            services: StubServices(snapshots: snapshots, desktopObservation: observation),
            allowedOperations: [
                .desktopObservation,
                .storeObservationSnapshot,
                .storeScreenshot,
                .storeDetectionResult,
            ])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = try await RemoteDesktopObservationService(
            client: self.makeNegotiatedClient(
                socketPath: socketPath,
                requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true,
            artifactInstallationPreflight: {
                try FileManager.default.removeItem(at: outputURL)
                try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: false)
            })

        let result = try await remote.observe(DesktopObservationRequest(
            target: .windowID(42),
            capture: DesktopCaptureOptions(
                roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
            output: DesktopObservationOutputOptions(
                path: outputURL.path,
                saveRawScreenshot: true,
                saveSnapshot: true,
                snapshotID: snapshotID)))

        #expect(result.files.rawScreenshotPath == nil)
        #expect(result.capture.savedPath == nil)
        #expect(result.diagnostics.warnings.contains {
            $0.contains("Snapshot publication succeeded") && $0.contains("could not be published")
        })
        let snapshot = try #require(try await snapshots.getUIAutomationSnapshot(snapshotId: snapshotID))
        let storedPath = try #require(snapshot.screenshotPath)
        #expect(FileManager.default.fileExists(atPath: storedPath))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path) == ["conflicted.png"])
        try await snapshots.cleanSnapshot(snapshotId: snapshotID)
        await host.stop()
    }

    @Test
    func `remote ROI discards staged artifacts when publication preflight throws`() async throws {
        let socketPath = "/tmp/peekaboo-remote-staged-cleanup-roi-\(UUID().uuidString).sock"
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-remote-staged-cleanup-roi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let outputURL = outputDirectory.appendingPathComponent("existing.png")
        let existingData = Data("existing-public-output".utf8)
        try existingData.write(to: outputURL, options: .atomic)
        let observation = ROIFileObservationService(mode: .valid)
        let server = self.makeROIServer(services: StubServices(desktopObservation: observation))
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = try await RemoteDesktopObservationService(
            client: self.makeNegotiatedClient(
                socketPath: socketPath,
                requestTimeoutSec: 1),
            supportsExactWindowROIObservation: true,
            artifactInstallationPreflight: {
                throw StagedArtifactPreflightError.expected
            })

        await #expect(throws: StagedArtifactPreflightError.expected) {
            _ = try await remote.observe(DesktopObservationRequest(
                target: .windowID(42),
                capture: DesktopCaptureOptions(
                    roi: CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))),
                output: DesktopObservationOutputOptions(
                    path: outputURL.path,
                    saveRawScreenshot: true)))
        }

        #expect(try Data(contentsOf: outputURL) == existingData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path) == ["existing.png"])
        await host.stop()
    }

    @Test
    func `remote ROI rejects full window pixels behind a valid crop receipt`() async throws {
        let socketPath = "/tmp/peekaboo-remote-mismatched-roi-\(UUID().uuidString).sock"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-remote-mismatched-roi-public-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let observation = ROIFileObservationService(mode: .mismatchedArtifact)
        let server = self.makeROIServer(services: StubServices(desktopObservation: observation))
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = try await RemoteDesktopObservationService(
            client: self.makeNegotiatedClient(
                socketPath: socketPath,
                requestTimeoutSec: 1),
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
        let server = self.makeROIServer(services: StubServices(desktopObservation: observation))
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = try await RemoteDesktopObservationService(
            client: self.makeNegotiatedClient(
                socketPath: socketPath,
                requestTimeoutSec: 1),
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
        let server = self.makeROIServer(services: StubServices(desktopObservation: observation))
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = try await RemoteDesktopObservationService(
            client: self.makeNegotiatedClient(
                socketPath: socketPath,
                requestTimeoutSec: 1),
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
        let server = self.makeROIServer(
            services: StubServices(desktopObservation: WrongWindowROIObservationService()))
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = try await RemoteDesktopObservationService(
            client: self.makeNegotiatedClient(
                socketPath: socketPath,
                requestTimeoutSec: 1,
                protocolVersion: Self.receiptlessProtocolVersion),
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
        let server = self.makeROIServer(
            services: StubServices(desktopObservation: FailingROIObservationService(error: .outOfBounds)))
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = try await RemoteDesktopObservationService(
            client: self.makeNegotiatedClient(
                socketPath: socketPath,
                requestTimeoutSec: 1,
                protocolVersion: Self.receiptlessProtocolVersion),
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
private final class PathlessTrackingObservationService: DesktopObservationServiceProtocol {
    private(set) var lastRequest: DesktopObservationRequest?

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.lastRequest = request
        return DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: StubScreenCaptureService.sampleData,
                metadata: CaptureMetadata(size: .init(width: 1, height: 1), mode: .screen)),
            elements: nil)
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
        case validWithElements
        case ignored
        case mismatchedArtifact
        case mismatchedAnnotatedArtifact
        case mismatchedCaptureData
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
            let bounds = CGRect(x: 100, y: 200, width: 100, height: 80)
            let identity = WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: 123,
                ownerProcessStartIdentity: 456,
                capturedBounds: bounds)
            let context = WindowContext(
                applicationName: "ROI Fixture",
                applicationBundleId: "test.valid-roi",
                applicationProcessId: 123,
                windowTitle: "ROI",
                windowID: 42,
                windowBounds: bounds,
                windowMutationIdentity: identity)
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
                    detectionContext: context),
                capture: CaptureResult(
                    imageData: Self.croppedData,
                    savedPath: path,
                    metadata: CaptureMetadata(
                        size: CGSize(width: 100, height: 80),
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
                        diagnostics: Self.captureDiagnostics(
                            size: CGSize(width: 100, height: 80),
                            scale: request.capture.scale))),
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
        let windowContext = WindowContext(
            applicationName: "ROI Fixture",
            applicationBundleId: "test.valid-roi",
            applicationProcessId: 123,
            windowTitle: "ROI",
            windowID: 42,
            windowBounds: bounds,
            windowMutationIdentity: identity)
        let elements = request.detection.mode != .none
            ? ElementDetectionResult(
                snapshotId: request.output.snapshotID ?? "roi-fixture",
                screenshotPath: path,
                elements: DetectedElements(buttons: [DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Fixture",
                    bounds: CGRect(x: 1, y: 1, width: 5, height: 5),
                    isEnabled: true)]),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 1,
                    method: "fixture",
                    windowContext: WindowContext(
                        applicationName: windowContext.applicationName,
                        applicationBundleId: windowContext.applicationBundleId,
                        applicationProcessId: windowContext.applicationProcessId,
                        windowTitle: windowContext.windowTitle,
                        windowID: windowContext.windowID,
                        windowBounds: windowContext.windowBounds,
                        windowMutationIdentity: windowContext.windowMutationIdentity,
                        shouldFocusWebContent: request.detection.allowWebFocusFallback,
                        includeMenuBarElements: request.detection.includeMenuBarElements,
                        traversalBudget: request.detection.traversalBudget)))
            : nil
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
                detectionContext: windowContext),
            capture: CaptureResult(
                imageData: self.mode == .mismatchedCaptureData ? Self.fullWindowData : Self.croppedData,
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
                    diagnostics: Self.captureDiagnostics(
                        size: roi.bounds.size,
                        scale: request.capture.scale),
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
            elements: elements,
            files: DesktopObservationFiles(
                rawScreenshotPath: path,
                annotatedScreenshotPath: request.output.saveAnnotatedScreenshot
                    ? ObservationOutputWriter.annotatedScreenshotPath(forRawScreenshotPath: path)
                    : nil))
    }

    private static func captureDiagnostics(
        size: CGSize,
        scale: CaptureScalePreference) -> CaptureDiagnostics
    {
        CaptureDiagnostics(
            requestedScale: scale,
            nativeScale: 2,
            outputScale: scale == .native ? 2 : 1,
            scaleSource: "fixture",
            finalPixelSize: size,
            engine: "ScreenCaptureKit")
    }
}

private enum StagedArtifactPreflightError: Error {
    case expected
}

@MainActor
private final class LegacyEmptyExactObservationService: DesktopObservationServiceProtocol {
    private(set) var requests: [DesktopObservationRequest] = []

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.requests.append(request)
        let bounds = CGRect(x: 100, y: 200, width: 100, height: 80)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 456,
            capturedBounds: bounds)
        let context = WindowContext(
            applicationName: "Legacy Fixture",
            applicationBundleId: "test.legacy-empty",
            applicationProcessId: 123,
            windowTitle: "Empty",
            windowID: 42,
            windowBounds: bounds,
            windowMutationIdentity: identity)
        let elements: ElementDetectionResult? = request.detection.mode == .none
            ? nil
            : ElementDetectionResult(
                snapshotId: request.output.snapshotID ?? "legacy-empty",
                screenshotPath: request.output.path ?? "",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0.01,
                    elementCount: 0,
                    method: "legacy AX",
                    windowContext: WindowContext(
                        applicationName: context.applicationName,
                        applicationBundleId: context.applicationBundleId,
                        applicationProcessId: context.applicationProcessId,
                        windowTitle: context.windowTitle,
                        windowID: context.windowID,
                        windowBounds: context.windowBounds,
                        windowMutationIdentity: context.windowMutationIdentity,
                        shouldFocusWebContent: request.detection.allowWebFocusFallback,
                        includeMenuBarElements: request.detection.includeMenuBarElements,
                        traversalBudget: request.detection.traversalBudget)))
        return DesktopObservationResult(
            target: ResolvedObservationTarget(
                kind: .windowID(42),
                app: ApplicationIdentity(
                    processIdentifier: 123,
                    processStartIdentity: 456,
                    bundleIdentifier: "test.legacy-empty",
                    name: "Legacy Fixture"),
                window: WindowIdentity(windowID: 42, title: "Empty", bounds: bounds, index: 0),
                bounds: bounds,
                detectionContext: context),
            capture: CaptureResult(
                imageData: Data([9]),
                metadata: CaptureMetadata(
                    size: bounds.size,
                    mode: .window,
                    applicationInfo: ServiceApplicationInfo(
                        processIdentifier: 123,
                        processStartIdentity: 456,
                        bundleIdentifier: "test.legacy-empty",
                        name: "Legacy Fixture"),
                    windowInfo: ServiceWindowInfo(
                        windowID: 42,
                        title: "Empty",
                        bounds: bounds,
                        mutationIdentity: identity),
                    diagnostics: CaptureDiagnostics(
                        requestedScale: request.capture.scale,
                        nativeScale: 2,
                        outputScale: request.capture.scale == .native ? 2 : 1,
                        scaleSource: "fixture",
                        finalPixelSize: bounds.size,
                        engine: "ScreenCaptureKit"))),
            elements: elements,
            files: DesktopObservationFiles(rawScreenshotPath: request.output.path))
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
