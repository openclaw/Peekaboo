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
        #expect(!PeekabooBridgeRequest.dialogFindActive(.init(
            windowTitle: "Save",
            appName: nil)).mayMutateDesktop)
        #expect(!PeekabooBridgeRequest.dialogListElements(.init(
            windowTitle: "Open",
            appName: nil)).mayMutateDesktop)
    }

    @Test
    @MainActor
    func `desktop observation bridge operation forwards request without returning image bytes`() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-bridge-routing-\(UUID().uuidString).png")
        try StubScreenCaptureService.sampleData.write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }
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
            output: DesktopObservationOutputOptions(path: outputURL.path, saveRawScreenshot: true))
        let requestData = try JSONEncoder.peekabooBridgeEncoder()
            .encode(PeekabooBridgeRequest.desktopObservation(request))
        let response = try await self.decode(server.decodeAndHandle(requestData, peer: nil))

        guard case let .desktopObservation(result) = response else {
            Issue.record("Expected desktopObservation response, got \(response)")
            return
        }

        #expect(services.desktopObservationStub.lastRequest == request)
        #expect(result.capture.savedPath == outputURL.path)
        #expect(result.files.rawScreenshotPath == outputURL.path)
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
            allowedOperations: [.browserStatus, .browserConnect, .browserExecute],
            processStartIdentityProvider: { processIdentifier in
                processIdentifier == 42 ? 10042 : nil
            })

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
        #expect(status.connectionReceipt?.processIdentifier == 42)
        #expect(status.connectionReceipt?.processStartIdentityDecimal == "10042")

        let connectRequest = PeekabooBridgeRequest.browserConnect(.init(
            channel: "stable",
            browserURL: "http://127.0.0.1:9222"))
        let connectData = try JSONEncoder.peekabooBridgeEncoder().encode(connectRequest)
        let connectResponse = try await self.decode(server.decodeAndHandle(connectData, peer: nil))
        guard case .browserStatus = connectResponse else {
            Issue.record("Expected browserStatus connect response, got \(connectResponse)")
            return
        }
        #expect(services.lastBrowserConnectTarget?.channel == "stable")
        #expect(services.lastBrowserConnectTarget?.browserURL == "http://127.0.0.1:9222")

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
        #expect(toolResponse.connectionReceipt == nil)
        #expect(services.lastBrowserExecute?.toolName == "list_pages")
        #expect(services.lastBrowserExecute?.channel == "canary")
        #expect(services.lastExpectedBrowserConnectionReceipt == nil)

        let sequenceRequest = PeekabooBridgeRequest.browserExecute(.init(calls: [
            .init(toolName: "click", arguments: ["uid": .string("2_1")]),
            .init(toolName: "type_text", arguments: ["text": .string("value")]),
        ], channel: "stable"))
        let sequenceData = try JSONEncoder.peekabooBridgeEncoder().encode(sequenceRequest)
        _ = try await self.decode(server.decodeAndHandle(sequenceData, peer: nil))
        #expect(services.lastBrowserExecute?.resolvedCalls.map(\.toolName) == ["click", "type_text"])
    }

    @Test
    @MainActor
    func `daemon activity ends once after successful routing`() async throws {
        let daemonControl = CountingConditionalDaemonControl(shouldAdmit: true)
        let server = self.makeServer(
            services: StubServices(),
            allowedOperations: [.permissionsStatus],
            daemonControl: daemonControl)

        let handled = try await server.route(.permissionsStatus, peer: nil)

        guard case .permissionsStatus = handled.response else {
            Issue.record("Expected permissions status response")
            return
        }
        #expect(daemonControl.admissionCount == 1)
        #expect(daemonControl.admittedCount == 1)
        #expect(daemonControl.startCount == 0)
        #expect(daemonControl.endCount == 1)
        #expect(daemonControl.activeCount == 0)
    }

    @Test
    @MainActor
    func `daemon activity ends once when finalization rejects a missing exact target`() async {
        let daemonControl = CountingConditionalDaemonControl(shouldAdmit: true)
        let server = self.makeServer(
            services: StubServices(),
            allowedOperations: [.click],
            daemonControl: daemonControl)
        let request = PeekabooBridgeRequest.click(.init(
            target: .elementId("B1"),
            clickType: .single))

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                try await server.route(request, peer: nil)
            }
        }

        #expect(daemonControl.admissionCount == 1)
        #expect(daemonControl.admittedCount == 1)
        #expect(daemonControl.startCount == 0)
        #expect(daemonControl.endCount == 1)
        #expect(daemonControl.activeCount == 0)
    }

    @Test
    @MainActor
    func `legacy daemon activity ends once when the handler throws`() async {
        let services = StubServices()
        services.browserStatusError = PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "Injected browser status failure")
        let daemonControl = CountingLegacyDaemonControl()
        let server = self.makeServer(
            services: services,
            allowedOperations: [.browserStatus],
            daemonControl: daemonControl)

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await server.route(.browserStatus(.init(channel: "stable")), peer: nil)
        }

        #expect(daemonControl.startCount == 1)
        #expect(daemonControl.endCount == 1)
        #expect(daemonControl.activeCount == 0)
    }

    @Test
    @MainActor
    func `daemon activity ends once when the handler is cancelled`() async {
        let services = StubServices()
        services.browserStatusError = CancellationError()
        let daemonControl = CountingConditionalDaemonControl(shouldAdmit: true)
        let server = self.makeServer(
            services: services,
            allowedOperations: [.browserStatus],
            daemonControl: daemonControl)

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await server.route(.browserStatus(.init(channel: "stable")), peer: nil)
        }

        #expect(daemonControl.admissionCount == 1)
        #expect(daemonControl.admittedCount == 1)
        #expect(daemonControl.startCount == 0)
        #expect(daemonControl.endCount == 1)
        #expect(daemonControl.activeCount == 0)
    }

    @Test
    @MainActor
    func `daemon admission refusal does not end unstarted activity`() async {
        let services = StubServices()
        let daemonControl = CountingConditionalDaemonControl(shouldAdmit: false)
        let server = self.makeServer(
            services: services,
            allowedOperations: [.browserStatus],
            daemonControl: daemonControl)

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await server.route(.browserStatus(.init(channel: "stable")), peer: nil)
        }

        #expect(services.lastBrowserStatusChannel == nil)
        #expect(daemonControl.admissionCount == 1)
        #expect(daemonControl.admittedCount == 0)
        #expect(daemonControl.startCount == 0)
        #expect(daemonControl.endCount == 0)
        #expect(daemonControl.activeCount == 0)
    }

    @MainActor
    private func makeServer(
        services: any PeekabooBridgeServiceProviding,
        allowedOperations: Set<PeekabooBridgeOperation>,
        daemonControl: any PeekabooDaemonControlProviding) -> PeekabooBridgeServer
    {
        PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: allowedOperations,
            daemonControl: daemonControl,
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: true,
                    postEvent: true)
            })
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
private final class CountingConditionalDaemonControl: PeekabooConditionalDaemonControlProviding {
    private let shouldAdmit: Bool
    private(set) var admissionCount = 0
    private(set) var admittedCount = 0
    private(set) var startCount = 0
    private(set) var endCount = 0
    private(set) var activeCount = 0

    init(shouldAdmit: Bool) {
        self.shouldAdmit = shouldAdmit
    }

    func daemonStatus() async -> PeekabooDaemonStatus {
        Self.status(activeRequests: self.activeCount)
    }

    func requestStop() async -> Bool {
        true
    }

    func requestStop(expectedPID _: pid_t) async -> Bool {
        true
    }

    func admitActivity(operation _: PeekabooBridgeOperation) async -> Bool {
        self.admissionCount += 1
        guard self.shouldAdmit else { return false }
        self.admittedCount += 1
        self.activeCount += 1
        return true
    }

    func recordActivityStart(operation _: PeekabooBridgeOperation) async {
        self.startCount += 1
        self.activeCount += 1
    }

    func recordActivityEnd(operation _: PeekabooBridgeOperation) async {
        self.endCount += 1
        self.activeCount -= 1
    }

    private static func status(activeRequests: Int) -> PeekabooDaemonStatus {
        PeekabooDaemonStatus(
            running: true,
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: Date(),
            mode: .manual,
            activity: .init(
                activeRequests: activeRequests,
                lastActivityAt: Date(),
                idleTimeoutSeconds: nil,
                idleExitAt: nil))
    }
}

@MainActor
private final class CountingLegacyDaemonControl: PeekabooDaemonControlProviding {
    private(set) var startCount = 0
    private(set) var endCount = 0
    private(set) var activeCount = 0

    func daemonStatus() async -> PeekabooDaemonStatus {
        PeekabooDaemonStatus(
            running: true,
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: Date(),
            mode: .manual,
            activity: .init(
                activeRequests: self.activeCount,
                lastActivityAt: Date(),
                idleTimeoutSeconds: nil,
                idleExitAt: nil))
    }

    func requestStop() async -> Bool {
        true
    }

    func recordActivityStart(operation _: PeekabooBridgeOperation) async {
        self.startCount += 1
        self.activeCount += 1
    }

    func recordActivityEnd(operation _: PeekabooBridgeOperation) async {
        self.endCount += 1
        self.activeCount -= 1
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
