import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeCapabilityTests {
    @Test
    @MainActor
    func `production bridge classifier preserves lookup identity`() {
        let cases: [(PeekabooError, PeekabooBridgeErrorKind, String?)] = [
            (.appNotFound("Safari"), .appNotFound, "Safari"),
            (.windowNotFound(criteria: "Settings"), .windowNotFound, "Settings"),
            (.menuNotFound("Finder"), .menuNotFound, "Finder"),
            (.menuItemNotFound("New Window"), .menuItemNotFound, "New Window"),
            (.snapshotStale("window moved"), .snapshotStale, "window moved"),
        ]

        for (error, expectedKind, expectedContext) in cases {
            let envelope = PeekabooBridgeServer.bridgeErrorEnvelope(for: error, operation: .targetedClick)
            #expect(envelope.kind == expectedKind)
            #expect(envelope.context == expectedContext)
        }
    }

    @Test
    @MainActor
    func `production bridge classifier preserves Dock identity and messages`() {
        let cases: [(DockError, PeekabooBridgeOperation, PeekabooBridgeErrorKind, String)] = [
            (.itemNotFound("Safari"), .findDockItem, .dockItemNotFound, "Dock item not found: Safari"),
            (
                .menuItemNotFound("New Window"),
                .rightClickDockItem,
                .menuItemNotFound,
                "Dock menu item not found: New Window"),
        ]
        for (error, operation, expectedKind, expectedMessage) in cases {
            let envelope = PeekabooBridgeServer.bridgeErrorEnvelope(for: error, operation: operation)
            #expect(envelope.code == .notFound)
            #expect(envelope.kind == expectedKind)
            #expect(envelope.message == expectedMessage)
        }
    }

    @Test
    @MainActor
    func `production bridge classifier converts legacy lookup errors`() {
        let cases: [(NotFoundError, PeekabooBridgeErrorKind, String?)] = [
            (
                NotFoundError(
                    code: .menuNotFound,
                    userMessage: "Menu not found",
                    context: ["application": "Finder"]),
                .menuNotFound,
                "Finder"),
            (
                NotFoundError(
                    code: .menuNotFound,
                    userMessage: "Menu item not found",
                    context: ["application": "Finder", "menuItem": "New Window"]),
                .menuItemNotFound,
                "New Window"),
        ]

        for (error, expectedKind, expectedContext) in cases {
            let envelope = PeekabooBridgeServer.bridgeErrorEnvelope(for: error, operation: .listMenus)
            #expect(envelope.code == .notFound)
            #expect(envelope.kind == expectedKind)
            #expect(envelope.context == expectedContext)
        }
    }

    @Test
    @MainActor
    func `production bridge classifier preserves indeterminate input delivery`() throws {
        let error = InputDeliveryIndeterminateError(
            operation: .type,
            emittedUnitCount: 1,
            causeDescription: "window focus drifted",
            delivery: .init(mechanism: .accessibilityValue, mode: .background))

        let envelope = PeekabooBridgeServer.bridgeErrorEnvelope(for: error, operation: .targetedTypeActions)

        #expect(envelope.code == .internalError)
        #expect(envelope.operationMayHaveCompleted)
        #expect(envelope.message.contains("do not retry blindly"))
        #expect(envelope.message.contains("window focus drifted"))
        let failure = try #require(envelope.desktopActionFailure)
        #expect(failure.outcome.route == .bridge)
        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.evidence == .completionUnknown)
        #expect(failure.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 1)
        #expect(failure.outcome.projection.requiresFreshObservation)
        #expect(failure.causeDescription == "window focus drifted")
    }

    @Test
    @MainActor
    func `production bridge classifier preserves standardized capture failure`() {
        let envelope = PeekabooBridgeServer.bridgeErrorEnvelope(
            for: PeekabooError.captureFailed("ScreenCaptureKit owner refused before dispatch"),
            operation: .desktopObservation)

        #expect(envelope.code == .internalError)
        #expect(envelope.standardizedErrorCode == .captureFailed)
        #expect(!envelope.operationMayHaveCompleted)
    }

    @Test
    func `only owner aware classic observation defers handshake screen permission`() {
        let classic = PeekabooBridgeRequest.desktopObservation(DesktopObservationRequest(
            target: .screen(index: 0),
            capture: DesktopCaptureOptions(engine: .legacy),
            detection: DesktopDetectionOptions(mode: .none)))
        let modern = PeekabooBridgeRequest.desktopObservation(DesktopObservationRequest(
            target: .screen(index: 0),
            capture: DesktopCaptureOptions(engine: .modern),
            detection: DesktopDetectionOptions(mode: .none)))
        let operations: Set<PeekabooBridgeOperation> = [.desktopObservation]
        let ownerCapability: Set<String> = [PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership]

        #expect(PeekabooBridgeServer.defersClassicScreenRecordingPermission(
            for: classic,
            hostCapabilities: ownerCapability,
            allowedOperations: operations))
        #expect(!PeekabooBridgeServer.defersClassicScreenRecordingPermission(
            for: classic,
            hostCapabilities: [],
            allowedOperations: operations))
        #expect(!PeekabooBridgeServer.defersClassicScreenRecordingPermission(
            for: modern,
            hostCapabilities: ownerCapability,
            allowedOperations: operations))
    }

    @Test
    func `unknown bridge error kinds decode as untyped errors`() throws {
        let data = Data(
            #"{"code":"invalidRequest","message":"Future error","kind":"futureErrorKind","context":"S1"}"#.utf8)

        let envelope = try JSONDecoder().decode(PeekabooBridgeErrorEnvelope.self, from: data)

        #expect(envelope.code == .invalidRequest)
        #expect(envelope.message == "Future error")
        #expect(envelope.kind == nil)
        #expect(envelope.context == "S1")
    }

    @Test
    func `handshake omits transactional capabilities for legacy snapshot managers`() async throws {
        let snapshots = await MainActor.run { LegacySnapshotManager() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(snapshots: snapshots),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let handshake = try await self.handshake(server: server, hostKind: .gui)

        #expect(!handshake.supportedOperations.contains(.invalidateImplicitLatestSnapshot))
        #expect(handshake.enabledOperations?.contains(.invalidateImplicitLatestSnapshot) != true)
        #expect(!handshake.supportedOperations.contains(.storeObservationSnapshot))
        #expect(handshake.enabledOperations?.contains(.storeObservationSnapshot) != true)
        #expect(!handshake.supportedOperations.contains(.beginSnapshotMutation))
        #expect(!handshake.supportedOperations.contains(.finishSnapshotMutation))
        #expect(handshake.enabledOperations?.contains(.beginSnapshotMutation) != true)
        #expect(handshake.enabledOperations?.contains(.finishSnapshotMutation) != true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.explicitSnapshotPublication) != true)

        await #expect(throws: SnapshotError.self) {
            _ = try await snapshots.createExplicitSnapshot()
        }

        await #expect(throws: SnapshotError.self) {
            try await snapshots.storeObservationSnapshot(SnapshotObservationPublicationRequest(
                screenshot: SnapshotScreenshotRequest(
                    snapshotId: "existing",
                    screenshotPath: "/tmp/unused.png",
                    applicationBundleId: nil,
                    applicationProcessId: nil,
                    applicationName: nil,
                    windowTitle: nil,
                    windowBounds: nil),
                detectionResult: nil,
                annotatedScreenshotPath: nil))
        }
    }

    @Test
    func `application relaunch stays inside one daemon bridge request`() async throws {
        let applications = await MainActor.run { StubApplicationService() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applications),
                hostKind: .onDemand,
                allowlistedTeams: [],
                allowlistedBundles: [],
                daemonControl: StubDaemonControl())
        }
        let request = ApplicationRelaunchRequest(
            targetIdentifier: "PID:123",
            expectedTargetIdentity: ApplicationProcessIdentity(
                processIdentifier: 123,
                processStartIdentity: 456),
            launchRequest: ApplicationLaunchRequest(
                applicationIdentifier: "dev.stub",
                activates: true,
                waitUntilReady: true),
            force: true,
            waitSeconds: 0)
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeRequest.relaunchApplicationWithOptions(request))

        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: responseData)
        guard case .application = response else {
            Issue.record("Expected application response, got \(response)")
            return
        }
        let requests = await MainActor.run { applications.relaunchRequests }
        #expect(requests == [request])
    }

    @Test
    func `current daemon advertises exact browser connection receipts`() async throws {
        let browserOperations: Set<PeekabooBridgeOperation> = [
            .browserStatus,
            .browserConnect,
            .browserDisconnect,
            .browserExecute,
        ]
        let legacyVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 25)
        let legacyRange = PeekabooBridgeConstants.minimumProtocolVersion...legacyVersion
        let current = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                hostKind: .onDemand,
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: browserOperations)
        }
        let legacy = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                hostKind: .onDemand,
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: legacyRange,
                allowedOperations: browserOperations)
        }

        let currentHandshake = try await self.handshake(server: current, hostKind: .onDemand)
        #expect(currentHandshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.browserConnectionReceipts) == true)
        #expect(currentHandshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.nativeBrowserConnectionBinding) != true)

        let legacyRequest = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 25),
            client: .init(
                bundleIdentifier: "dev.peeka.legacy-browser",
                teamIdentifier: "TEAMID",
                processIdentifier: getpid(),
                hostname: Host.current().name),
            requestedHostKind: .onDemand))
        let legacyData = try await legacy.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(legacyRequest),
            peer: nil)
        let legacyResponse = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: legacyData)
        guard case let .handshake(legacyHandshake) = legacyResponse else {
            Issue.record("Expected legacy handshake")
            return
        }
        #expect(legacyHandshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.browserConnectionReceipts) != true)

        let protocol133 = PeekabooBridgeProtocolVersion(major: 1, minor: 33)
        let downgraded = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                hostKind: .onDemand,
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: PeekabooBridgeConstants.minimumProtocolVersion...protocol133,
                allowedOperations: browserOperations)
        }
        let downgradedRequest = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: protocol133,
            client: .init(
                bundleIdentifier: "dev.peeka.browser-1-33",
                teamIdentifier: "TEAMID",
                processIdentifier: getpid(),
                hostname: Host.current().name),
            requestedHostKind: .onDemand))
        let downgradedData = try await downgraded.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(downgradedRequest),
            peer: nil)
        let downgradedResponse = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: downgradedData)
        guard case let .handshake(downgradedHandshake) = downgradedResponse else {
            Issue.record("Expected downgraded handshake")
            return
        }
        #expect(downgradedHandshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.browserConnectionReceipts) == true)
        #expect(downgradedHandshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.nativeBrowserConnectionBinding) != true)
    }

    private func handshake(
        server: PeekabooBridgeServer,
        hostKind: PeekabooBridgeHostKind) async throws -> PeekabooBridgeHandshakeResponse
    {
        let request = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            client: .init(
                bundleIdentifier: "dev.peeka.cli",
                teamIdentifier: "TEAMID",
                processIdentifier: getpid(),
                hostname: Host.current().name),
            requestedHostKind: hostKind))
        let responseData = try await server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil)
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: responseData)
        guard case let .handshake(handshake) = response else {
            throw PeekabooError.operationError(message: "Expected handshake response")
        }
        return handshake
    }
}

@MainActor
private final class LegacySnapshotManager: SnapshotManagerProtocol {
    func createSnapshot() async throws -> String {
        fatalError("unused")
    }

    func storeDetectionResult(snapshotId _: String, result _: ElementDetectionResult) async throws {
        fatalError("unused")
    }

    func getDetectionResult(snapshotId _: String) async throws -> ElementDetectionResult? {
        fatalError("unused")
    }

    func getMostRecentSnapshot() async -> String? {
        fatalError("unused")
    }

    func getMostRecentSnapshot(applicationBundleId _: String) async -> String? {
        fatalError("unused")
    }

    func listSnapshots() async throws -> [SnapshotInfo] {
        fatalError("unused")
    }

    func cleanSnapshot(snapshotId _: String) async throws {
        fatalError("unused")
    }

    func cleanSnapshotsOlderThan(days _: Int) async throws -> Int {
        fatalError("unused")
    }

    func cleanAllSnapshots() async throws -> Int {
        fatalError("unused")
    }

    func getSnapshotStoragePath() -> String {
        fatalError("unused")
    }

    func storeScreenshot(_: SnapshotScreenshotRequest) async throws {
        fatalError("unused")
    }

    func storeAnnotatedScreenshot(snapshotId _: String, annotatedScreenshotPath _: String) async throws {
        fatalError("unused")
    }

    func getElement(snapshotId _: String, elementId _: String) async throws -> UIElement? {
        fatalError("unused")
    }

    func findElements(snapshotId _: String, matching _: String) async throws -> [UIElement] {
        fatalError("unused")
    }

    func getUIAutomationSnapshot(snapshotId _: String) async throws -> UIAutomationSnapshot? {
        fatalError("unused")
    }
}
