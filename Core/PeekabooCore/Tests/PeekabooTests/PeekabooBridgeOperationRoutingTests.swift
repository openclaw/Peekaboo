import Foundation
import PeekabooAutomationKit
import PeekabooCore
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeOperationRoutingTests {
    private func decode(_ data: Data) throws -> PeekabooBridgeResponse {
        try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
    }

    @Test
    func `bridge mutation policy only gates focus capable observation`() {
        let backgroundCapture = DesktopCaptureOptions(focus: .background)
        let passiveObservation = DesktopObservationRequest(
            target: .screen(index: 0),
            capture: backgroundCapture,
            detection: DesktopDetectionOptions(mode: .none))
        let accessibilityObservation = DesktopObservationRequest(
            target: .screen(index: 0),
            capture: backgroundCapture,
            detection: DesktopDetectionOptions(mode: .accessibility))
        let webFocusObservation = DesktopObservationRequest(
            target: .screen(index: 0),
            capture: backgroundCapture,
            detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: true))
        let foregroundObservation = DesktopObservationRequest(
            target: .screen(index: 0),
            capture: DesktopCaptureOptions(focus: .foreground),
            detection: DesktopDetectionOptions(mode: .none))
        let openingMenuBarPopover = DesktopObservationRequest(
            target: .menubarPopover(hints: ["Control Center"], openIfNeeded: .init()),
            capture: backgroundCapture,
            detection: DesktopDetectionOptions(mode: .none))

        #expect(!PeekabooBridgeRequest.desktopObservation(passiveObservation).mayMutateDesktop)
        #expect(!PeekabooBridgeRequest.desktopObservation(accessibilityObservation).mayMutateDesktop)
        #expect(PeekabooBridgeRequest.desktopObservation(webFocusObservation).mayMutateDesktop)
        #expect(PeekabooBridgeRequest.desktopObservation(foregroundObservation).mayMutateDesktop)
        #expect(PeekabooBridgeRequest.desktopObservation(openingMenuBarPopover).mayMutateDesktop)
        #expect(!PeekabooBridgeRequest.detectElements(.init(
            imageData: Data(),
            snapshotId: nil,
            windowContext: nil)).mayMutateDesktop)
        #expect(!PeekabooBridgeRequest.inspectAccessibilityTree(.init(
            windowContext: nil)).mayMutateDesktop)
        #expect(PeekabooBridgeRequest.inspectAccessibilityTree(.init(
            windowContext: WindowContext(shouldFocusWebContent: true))).mayMutateDesktop)
        #expect(!PeekabooBridgeRequest.launchApplicationWithOptions(.init(
            applicationIdentifier: "Finder")).mayMutateDesktop)
        #expect(PeekabooBridgeRequest.launchApplicationWithOptions(.init(
            applicationIdentifier: "Finder",
            activates: true)).mayMutateDesktop)
        #expect(!PeekabooBridgeRequest.dialogFindActive(.init(
            windowTitle: nil,
            appName: "Calculator")).mayMutateDesktop)
        #expect(PeekabooBridgeRequest.dialogFindActive(.init(
            windowTitle: "Save",
            appName: nil)).mayMutateDesktop)
        #expect(PeekabooBridgeRequest.dialogListElements(.init(
            windowTitle: "Open",
            appName: nil)).mayMutateDesktop)
    }

    @Test
    @MainActor
    func `desktop observation bridge operation forwards request without returning image bytes`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: true, accessibility: true, appleScript: true, postEvent: true)
            })
        let request = DesktopObservationRequest(
            target: .screen(index: 0),
            detection: DesktopDetectionOptions(mode: .none),
            output: DesktopObservationOutputOptions(path: "/tmp/stub.png", saveRawScreenshot: true))
        let requestData = try JSONEncoder.peekabooBridgeEncoder()
            .encode(PeekabooBridgeRequest.desktopObservation(request))
        let response = try await self.decode(server.decodeAndHandle(requestData, peer: nil))

        guard case let .desktopObservation(result) = response else {
            Issue.record("Expected desktopObservation response, got \(response)")
            return
        }

        #expect(services.desktopObservationStub.lastRequest == request)
        #expect(result.capture.savedPath == "/tmp/stub.png")
        #expect(result.files.rawScreenshotPath == "/tmp/stub.png")
        #expect(result.capture.imageData.isEmpty)
    }

    @Test
    @MainActor
    func `serialized desktop observations each preserve their completed snapshot`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-bridge-observation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let observations = BlockingFirstDesktopObservationService()
        let admissions = BridgeAdmissionRecorder()
        let services = StubServices(
            snapshots: snapshots,
            desktopObservation: observations)
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation],
            desktopMutationWatermarkStore: store,
            permissionStatusEvaluator: { _ in admissions.record() })

        let firstData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeRequest.desktopObservation(Self.mutatingObservationRequest(snapshotID: "S1")))
        let secondData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeRequest.desktopObservation(Self.mutatingObservationRequest(snapshotID: "S2")))
        let firstTask = Task { await server.decodeAndHandle(firstData, peer: nil) }
        await observations.waitUntilFirstObservationStarted()
        let secondTask = Task { await server.decodeAndHandle(secondData, peer: nil) }
        await admissions.waitUntilSecondRequest()

        observations.releaseFirstObservation()
        let firstResponse = try await self.decode(firstTask.value)
        let secondResponse = try await self.decode(secondTask.value)

        for response in [firstResponse, secondResponse] {
            guard case let .desktopObservation(result) = response else {
                Issue.record("Expected desktop observation response, got \(response)")
                continue
            }
            #expect(result.diagnostics.desktopMutationPreservationAllowed == true)
            #expect(result.diagnostics.desktopMutationCompletedAt != nil)
        }
        #expect(observations.observationCount == 2)
    }

    @Test
    @MainActor
    func `browser bridge operations route through service provider`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.browserStatus, .browserExecute])

        let statusRequest = PeekabooBridgeRequest.browserStatus(.init(channel: "stable"))
        let statusData = try JSONEncoder.peekabooBridgeEncoder().encode(statusRequest)
        let statusResponse = try await self.decode(server.decodeAndHandle(statusData, peer: nil))

        guard case let .browserStatus(status) = statusResponse else {
            Issue.record("Expected browserStatus response, got \(statusResponse)")
            return
        }
        #expect(status.isConnected)
        #expect(status.toolCount == 1)
        #expect(services.lastBrowserStatusChannel == "stable")

        let executeRequest = PeekabooBridgeRequest.browserExecute(.init(
            toolName: "list_pages",
            arguments: ["page": .int(1)],
            channel: "canary"))
        let executeData = try JSONEncoder.peekabooBridgeEncoder().encode(executeRequest)
        let executeResponse = try await self.decode(server.decodeAndHandle(executeData, peer: nil))

        guard case let .browserToolResponse(toolResponse) = executeResponse else {
            Issue.record("Expected browserToolResponse response, got \(executeResponse)")
            return
        }
        #expect(toolResponse.isError == false)
        #expect(services.lastBrowserExecute?.toolName == "list_pages")
        #expect(services.lastBrowserExecute?.channel == "canary")
    }

    private static func mutatingObservationRequest(snapshotID: String) -> DesktopObservationRequest {
        DesktopObservationRequest(
            target: .screen(index: 0),
            capture: DesktopCaptureOptions(focus: .background),
            detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: true),
            output: DesktopObservationOutputOptions(snapshotID: snapshotID))
    }
}

@MainActor
private final class BridgeAdmissionRecorder {
    private var requestCount = 0
    private var requestCountWaiters: [CheckedContinuation<Void, Never>] = []

    func record() -> PermissionsStatus {
        self.requestCount += 1
        if self.requestCount >= 2 {
            self.requestCountWaiters.forEach { $0.resume() }
            self.requestCountWaiters.removeAll()
        }
        return PermissionsStatus(
            screenRecording: true,
            accessibility: true,
            appleScript: true,
            postEvent: true)
    }

    func waitUntilSecondRequest() async {
        guard self.requestCount < 2 else { return }
        await withCheckedContinuation { continuation in
            self.requestCountWaiters.append(continuation)
        }
    }
}

@MainActor
private final class BlockingFirstDesktopObservationService: DesktopObservationServiceProtocol {
    private(set) var observationCount = 0
    private var firstObservationStarted = false
    private var firstObservationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstObservationContinuation: CheckedContinuation<Void, Never>?

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.observationCount += 1
        if self.observationCount == 1 {
            self.firstObservationStarted = true
            self.firstObservationStartWaiters.forEach { $0.resume() }
            self.firstObservationStartWaiters.removeAll()
            await withCheckedContinuation { continuation in
                self.firstObservationContinuation = continuation
            }
        }
        return DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: StubScreenCaptureService.sampleData,
                savedPath: "/tmp/\(request.output.snapshotID ?? "stub").png",
                metadata: CaptureMetadata(
                    size: .init(width: 1, height: 1),
                    mode: .screen,
                    timestamp: Date())),
            elements: nil,
            files: DesktopObservationFiles())
    }

    func waitUntilFirstObservationStarted() async {
        guard !self.firstObservationStarted else { return }
        await withCheckedContinuation { continuation in
            self.firstObservationStartWaiters.append(continuation)
        }
    }

    func releaseFirstObservation() {
        self.firstObservationContinuation?.resume()
        self.firstObservationContinuation = nil
    }
}
