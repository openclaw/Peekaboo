import CoreGraphics
import Foundation
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooBridgeTestSupport
import PeekabooCore
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooBridge

// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
struct PeekabooBridgeTests {
    private struct BridgeDateEnvelope: Codable {
        let date: Date
    }

    private func decode(_ data: Data) throws -> PeekabooBridgeResponse {
        try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
    }

    @Test
    func `desktop observation timeout follows the requested overall budget`() {
        #expect(PeekabooBridgeClient.desktopObservationRequestTimeout(
            overallTimeout: 20,
            defaultTimeout: 10) == 25)
        #expect(PeekabooBridgeClient.desktopObservationRequestTimeout(
            overallTimeout: 2,
            defaultTimeout: 10) == 10)
        #expect(PeekabooBridgeClient.desktopObservationRequestTimeout(
            overallTimeout: nil,
            defaultTimeout: 10) == nil)
    }

    @Test
    func `bridge encoder preserves the legacy whole-second date format`() throws {
        let cutoff = Date(timeIntervalSince1970: 1_780_000_000.987_654)
        let encoded = try JSONEncoder.peekabooBridgeEncoder().encode(BridgeDateEnvelope(date: cutoff))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedDate = try #require(object["date"] as? String)
        let legacyDecoder = JSONDecoder()
        legacyDecoder.dateDecodingStrategy = .iso8601

        #expect(!encodedDate.contains("."))
        _ = try legacyDecoder.decode(BridgeDateEnvelope.self, from: encoded)

        let captureResponse = PeekabooBridgeResponse.capture(CaptureResult(
            imageData: Data(),
            savedPath: nil,
            metadata: CaptureMetadata(
                size: .init(width: 1, height: 1),
                mode: .screen,
                timestamp: cutoff)))
        let captureData = try JSONEncoder.peekabooBridgeEncoder().encode(captureResponse)
        _ = try legacyDecoder.decode(PeekabooBridgeResponse.self, from: captureData)
    }

    @Test
    func `bridge dates decode fractional and legacy whole seconds`() throws {
        let decoder = JSONDecoder.peekabooBridgeDecoder()
        let whole = try decoder.decode(
            BridgeDateEnvelope.self,
            from: Data(#"{"date":"2026-01-02T03:04:05Z"}"#.utf8))
        let fractional = try decoder.decode(
            BridgeDateEnvelope.self,
            from: Data(#"{"date":"2026-01-02T03:04:05.123456789Z"}"#.utf8))

        #expect(abs(fractional.date.timeIntervalSince(whole.date) - 0.123_456_789) < 0.000_000_2)
    }

    @Test
    func `mutation certificates preserve subsecond cutoffs without changing legacy date encoding`() throws {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000.987_654)
        let metadata = DetectionMetadata(
            detectionTime: 0,
            elementCount: 0,
            method: "accessibility",
            truncationInfo: nil,
            desktopMutationCompletedAt: cutoff,
            desktopMutationPreservationAllowed: true)
        let diagnostics = DesktopObservationDiagnostics(
            desktopMutationCompletedAt: cutoff,
            desktopMutationPreservationAllowed: true)
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        let decoder = JSONDecoder.peekabooBridgeDecoder()

        let metadataData = try encoder.encode(metadata)
        let diagnosticsData = try encoder.encode(diagnostics)
        let decodedMetadata = try decoder.decode(DetectionMetadata.self, from: metadataData)
        let decodedDiagnostics = try decoder.decode(DesktopObservationDiagnostics.self, from: diagnosticsData)
        let metadataObject = try #require(JSONSerialization.jsonObject(with: metadataData) as? [String: Any])
        let diagnosticsObject = try #require(
            JSONSerialization.jsonObject(with: diagnosticsData) as? [String: Any])

        #expect(decodedMetadata.desktopMutationCompletedAt == cutoff)
        #expect(decodedDiagnostics.desktopMutationCompletedAt == cutoff)
        #expect(metadataObject["desktopMutationCompletedAtReferenceDateSeconds"] != nil)
        #expect(metadataObject["desktopMutationCompletedAt"] == nil)
        #expect(diagnosticsObject["desktopMutationCompletedAtReferenceDateSeconds"] != nil)
        #expect(diagnosticsObject["desktopMutationCompletedAt"] == nil)
    }

    @Test
    func `mutation certificates decode the interim fractional date field`() throws {
        let fractionalDate = "2026-01-02T03:04:05.123456789Z"
        let metadataData = try JSONSerialization.data(withJSONObject: [
            "detectionTime": 0,
            "elementCount": 0,
            "method": "accessibility",
            "warnings": [],
            "isDialog": false,
            "desktopMutationCompletedAt": fractionalDate,
            "desktopMutationPreservationAllowed": true,
        ])
        let diagnosticsData = try JSONSerialization.data(withJSONObject: [
            "warnings": [],
            "desktopMutationCompletedAt": fractionalDate,
            "desktopMutationPreservationAllowed": true,
        ])
        let metadata = try JSONDecoder.peekabooBridgeDecoder().decode(
            DetectionMetadata.self,
            from: metadataData)
        let diagnostics = try JSONDecoder.peekabooBridgeDecoder().decode(
            DesktopObservationDiagnostics.self,
            from: diagnosticsData)

        #expect(metadata.desktopMutationCompletedAt == diagnostics.desktopMutationCompletedAt)
        #expect(metadata.desktopMutationPreservationAllowed == true)
        #expect(diagnostics.desktopMutationPreservationAllowed == true)
    }

    @Test
    func `bridge timeout and indeterminate responses preserve pending reservations`() {
        #expect(PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: PeekabooBridgeErrorEnvelope(
            code: .timeout,
            message: "Timed out")))
        #expect(PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: PeekabooBridgeErrorEnvelope(
            code: .internalError,
            message: "Bridge host returned no response")))
        #expect(PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: PeekabooBridgeErrorEnvelope(
            code: .decodingFailed,
            message: "Bridge host returned an invalid response")))
        #expect(!PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: PeekabooBridgeErrorEnvelope(
            code: .permissionDenied,
            message: "Permission denied")))
    }

    @Test
    @MainActor
    func `desktop observation misses retain typed Bridge errors`() {
        let notFound = PeekabooBridgeServer.bridgeErrorEnvelope(
            for: DesktopObservationError.targetNotFound("window id 42"),
            operation: .desktopObservation)
        #expect(notFound.code == .notFound)
        #expect(notFound.kind == .windowNotFound)

        let changed = PeekabooBridgeServer.bridgeErrorEnvelope(
            for: DesktopObservationError.targetChanged("window moved"),
            operation: .desktopObservation)
        #expect(changed.code == .notFound)
        #expect(changed.kind == .windowNotFound)

        let ambiguous = PeekabooBridgeServer.bridgeErrorEnvelope(
            for: DesktopObservationError.ambiguousWindowTitle("Settings", candidates: "1, 2"),
            operation: .desktopObservation)
        #expect(ambiguous.code == .invalidRequest)
    }

    @Test
    func `handshake negotiates version`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)

        let request = PeekabooBridgeRequest.handshake(
            .init(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                client: identity,
                requestedHostKind: .gui))

        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .handshake(handshake) = response else {
            Issue.record("Expected handshake response, got \(response)")
            return
        }

        #expect(handshake.negotiatedVersion == PeekabooBridgeConstants.protocolVersion)
        #expect(handshake.supportedOperations.contains(PeekabooBridgeOperation.permissionsStatus))
        #expect(handshake.supportedOperations.contains(PeekabooBridgeOperation.launchApplicationWithOptions))
        #expect(handshake.enabledOperations?.contains(PeekabooBridgeOperation.permissionsStatus) != false)
        #expect(handshake.permissions != nil)
        #expect(handshake.hostKind == PeekabooBridgeHostKind.gui)
    }

    @Test
    func `handshake accepts minimum compatible version`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)

        let request = PeekabooBridgeRequest.handshake(
            .init(
                protocolVersion: PeekabooBridgeConstants.minimumProtocolVersion,
                client: identity,
                requestedHostKind: .gui))

        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .handshake(handshake) = response else {
            Issue.record("Expected handshake response, got \(response)")
            return
        }

        #expect(handshake.negotiatedVersion == PeekabooBridgeConstants.minimumProtocolVersion)
        #expect(handshake.supportedOperations.contains(PeekabooBridgeOperation.permissionsStatus))
        #expect(!handshake.supportedOperations.contains(PeekabooBridgeOperation.targetedHotkey))
        #expect(!handshake.supportedOperations.contains(PeekabooBridgeOperation.requestPostEventPermission))
        #expect(!handshake.supportedOperations.contains(PeekabooBridgeOperation.setValue))
        #expect(!handshake.supportedOperations.contains(PeekabooBridgeOperation.performAction))
        #expect(!handshake.supportedOperations.contains(PeekabooBridgeOperation.desktopObservation))
    }

    @Test
    func `client handshake retries minimum compatible version`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-client-\(UUID().uuidString).sock"
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: PeekabooBridgeConstants.minimumProtocolVersion...PeekabooBridgeConstants
                    .minimumProtocolVersion)
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)

        try await host.startChecked()
        defer { Task { await host.stop() } }

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)

        let handshake = try await client.handshake(client: identity)

        #expect(handshake.negotiatedVersion == PeekabooBridgeConstants.minimumProtocolVersion)
    }

    @Test
    func `client handshake retries highest compatible minor version`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-client-\(UUID().uuidString).sock"
        let previousVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 1)
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: previousVersion...previousVersion)
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)

        try await host.startChecked()
        defer { Task { await host.stop() } }

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)

        let handshake = try await client.handshake(client: identity)

        #expect(handshake.negotiatedVersion == previousVersion)
        #expect(!handshake.supportedOperations.contains(PeekabooBridgeOperation.setValue))
        #expect(!handshake.supportedOperations.contains(PeekabooBridgeOperation.performAction))
        #expect(!handshake.supportedOperations.contains(PeekabooBridgeOperation.desktopObservation))
    }

    @Test
    func `handshake rejects unauthorized team`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: ["GOODTEAM"],
                allowlistedBundles: [])
        }

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "BADTEAM",
            processIdentifier: getpid(),
            hostname: Host.current().name)

        let peer = PeekabooBridgePeer(
            processIdentifier: getpid(),
            userIdentifier: getuid(),
            bundleIdentifier: identity.bundleIdentifier,
            teamIdentifier: identity.teamIdentifier)

        let request = PeekabooBridgeRequest.handshake(
            .init(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                client: identity,
                requestedHostKind: .gui))

        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: peer)
        let response = try self.decode(responseData)

        guard case let .error(envelope) = response else {
            Issue.record("Expected error response, got \(response)")
            return
        }
        #expect(envelope.code == PeekabooBridgeErrorCode.unauthorizedClient)
    }

    @Test
    func `handshake rejects unauthorized bundle`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: ["com.peekaboo.cli"])
        }

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)

        let peer = PeekabooBridgePeer(
            processIdentifier: getpid(),
            userIdentifier: getuid(),
            bundleIdentifier: identity.bundleIdentifier,
            teamIdentifier: identity.teamIdentifier)

        let request = PeekabooBridgeRequest.handshake(
            .init(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                client: identity,
                requestedHostKind: .gui))

        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: peer)
        let response = try self.decode(responseData)

        guard case let .error(envelope) = response else {
            Issue.record("Expected error response, got \(response)")
            return
        }
        #expect(envelope.code == PeekabooBridgeErrorCode.unauthorizedClient)
    }

    @Test
    func `every request rejects an unauthorized bundle even from an allowed team`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: ["GOODTEAM"],
                allowlistedBundles: ["com.peekaboo.cli"])
        }
        let peer = PeekabooBridgePeer(
            processIdentifier: getpid(),
            userIdentifier: getuid(),
            bundleIdentifier: "org.openclaw.unrelated",
            teamIdentifier: "GOODTEAM")

        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(PeekabooBridgeRequest.permissionsStatus)
        let responseData = await server.decodeAndHandle(requestData, peer: peer)
        let response = try self.decode(responseData)

        guard case let .error(envelope) = response else {
            Issue.record("Expected error response, got \(response)")
            return
        }
        #expect(envelope.code == PeekabooBridgeErrorCode.unauthorizedClient)
        #expect(envelope.message.contains("Bundle org.openclaw.unrelated"))
    }

    @Test
    func `every request accepts an allowlisted bundle and team`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: ["GOODTEAM"],
                allowlistedBundles: ["com.peekaboo.cli"])
        }
        let peer = PeekabooBridgePeer(
            processIdentifier: getpid(),
            userIdentifier: getuid(),
            bundleIdentifier: "com.peekaboo.cli",
            teamIdentifier: "GOODTEAM")

        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(PeekabooBridgeRequest.permissionsStatus)
        let responseData = await server.decodeAndHandle(requestData, peer: peer)
        let response = try self.decode(responseData)

        guard case .permissionsStatus = response else {
            Issue.record("Expected permissions response, got \(response)")
            return
        }
    }

    @Test
    func `handshake rejects incompatible protocol version`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)

        let request = PeekabooBridgeRequest.handshake(
            .init(
                protocolVersion: .init(major: 2, minor: 0),
                client: identity,
                requestedHostKind: .gui))

        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .error(envelope) = response else {
            Issue.record("Expected error response, got \(response)")
            return
        }
        #expect(envelope.code == PeekabooBridgeErrorCode.versionMismatch)
        #expect(envelope.message.contains("relaunch Peekaboo"))
        #expect(envelope.message.contains("bridge host updates"))
    }

    @Test
    func `unsupported operations are rejected when not allowlisted`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: [PeekabooBridgeOperation.permissionsStatus])
        }

        let request = PeekabooBridgeRequest
            .listMenus(PeekabooBridgeMenuListRequest(appIdentifier: "com.apple.TextEdit"))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .error(envelope) = response else {
            Issue.record("Expected error response, got \(response)")
            return
        }
        #expect(envelope.code == PeekabooBridgeErrorCode.operationNotSupported)
    }

    @Test
    func `permissions status round trips`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }

        let request = PeekabooBridgeRequest.permissionsStatus
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .permissionsStatus(status) = response else {
            Issue.record("Expected permissions status response, got \(response)")
            return
        }

        #expect(status.missingPermissions.isEmpty == status.allGranted)
        #expect(status.missingPermissions.count <= 3)
    }

    @Test
    func `permissions status does not launch AppleScript probe`() async throws {
        let recorder = PermissionLaunchRecorder()
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true },
                permissionStatusEvaluator: { allowAppleScriptLaunch in
                    recorder.status(allowAppleScriptLaunch: allowAppleScriptLaunch)
                })
        }

        let request = PeekabooBridgeRequest.permissionsStatus
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case .permissionsStatus = response else {
            Issue.record("Expected permissions status response, got \(response)")
            return
        }

        #expect(!recorder.allowAppleScriptLaunchValues.contains(true))
    }

    @Test
    func `request post event permission runs on bridge host`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { false },
                postEventAccessRequester: { true })
        }

        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeRequest.requestPostEventPermission)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .bool(granted) = response else {
            Issue.record("Expected bool response, got \(response)")
            return
        }

        #expect(granted)
    }

    @Test
    func `daemon status not advertised without provider`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)

        let request = PeekabooBridgeRequest.handshake(
            .init(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                client: identity,
                requestedHostKind: .gui))

        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .handshake(handshake) = response else {
            Issue.record("Expected handshake response, got \(response)")
            return
        }

        #expect(handshake.supportedOperations.contains(.daemonStatus) == false)
        #expect(handshake.supportedOperations.contains(.relaunchApplicationWithOptions) == false)
    }

    @Test
    func `targeted hotkey is not advertised without automation capability`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubNonTargetedServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)

        let request = PeekabooBridgeRequest.handshake(
            .init(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                client: identity,
                requestedHostKind: .gui))

        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .handshake(handshake) = response else {
            Issue.record("Expected handshake response, got \(response)")
            return
        }

        #expect(!handshake.supportedOperations.contains(.targetedHotkey))
        #expect(handshake.enabledOperations?.contains(.targetedHotkey) != true)
    }

    @Test
    func `element actions are not advertised without automation capability`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubNonTargetedServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)

        let request = PeekabooBridgeRequest.handshake(
            .init(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                client: identity,
                requestedHostKind: .gui))

        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .handshake(handshake) = response else {
            Issue.record("Expected handshake response, got \(response)")
            return
        }

        #expect(!handshake.supportedOperations.contains(.setValue))
        #expect(!handshake.supportedOperations.contains(.performAction))
        #expect(handshake.enabledOperations?.contains(.setValue) != true)
        #expect(handshake.enabledOperations?.contains(.performAction) != true)
    }

    @Test
    func `element actions are advertised with authenticated generation bound automation capability`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in Self.inputPermissions })
        }
        let fixture = try await Self.startTrustedHost(server: server)
        defer { Task { await fixture.host.stop() } }
        let handshake = fixture.handshake

        #expect(handshake.supportedOperations.contains(.setValue))
        #expect(handshake.supportedOperations.contains(.performAction))
        #expect(handshake.enabledOperations?.contains(.setValue) == true)
        #expect(handshake.enabledOperations?.contains(.performAction) == true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.processGenerationBoundElementMutations) == true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.setValueResultTargetBinding) == true)
        #expect(handshake.operationAttestation != nil)
        #expect(handshake.operationSessionAttestation != nil)

        let receiptless = try await self.decode(server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(PeekabooBridgeRequest.handshake(.init(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                client: Self.remoteClientIdentity,
                requestedHostKind: .gui))),
            peer: nil))
        guard case let .handshake(receiptlessHandshake) = receiptless else {
            Issue.record("Expected receiptless handshake, got \(receiptless)")
            return
        }
        #expect(!receiptlessHandshake.supportedOperations.contains(.setValue))
        #expect(!receiptlessHandshake.supportedOperations.contains(.performAction))
        #expect(receiptlessHandshake.operationSessionAttestation == nil)
        await fixture.host.stop()
    }

    @Test
    @MainActor
    func `daemon status round trips`() async throws {
        let daemon = StubDaemonControl()
        let server = PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            daemonControl: daemon)

        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(PeekabooBridgeRequest.daemonStatus)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .daemonStatus(status) = response else {
            Issue.record("Expected daemon status response, got \(response)")
            return
        }

        #expect(status.running == true)
        #expect(status.mode == .manual)
        #expect(status.activity?.activeRequests == 0)
        #expect(status.activity?.idleExitAt != nil)
    }

    @Test
    func `capture round trips through bridge`() async throws {
        let stub = await MainActor.run { StubServices() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: stub,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true })
        }

        let request = PeekabooBridgeRequest.captureFrontmost(
            PeekabooBridgeCaptureFrontmostRequest(
                visualizerMode: CaptureVisualizerMode.screenshotFlash,
                scale: CaptureScalePreference.logical1x))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .capture(result) = response else {
            Issue.record("Expected capture response, got \(response)")
            return
        }

        #expect(result.imageData == Data("stub-capture".utf8))
        #expect(result.metadata.mode == CaptureMode.frontmost)
    }

    @Test
    func `captureWindow forwards windowId when provided`() async throws {
        let stub = await MainActor.run { StubServices() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: stub,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true },
                windowOwnerProcessIdentifierProvider: { _ in 42 },
                windowBoundsProvider: { _ in CGRect(x: 10, y: 20, width: 300, height: 200) },
                processStartIdentityProvider: { _ in 7 })
        }

        let request = PeekabooBridgeRequest.captureWindow(
            PeekabooBridgeCaptureWindowRequest(
                appIdentifier: "",
                windowIndex: nil,
                windowId: 9001,
                visualizerMode: CaptureVisualizerMode.screenshotFlash,
                scale: CaptureScalePreference.logical1x))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case .capture = response else {
            Issue.record("Expected capture response, got \(response)")
            return
        }

        let lastWindowId = await MainActor.run { stub.screenCaptureStub.lastWindowId }
        #expect(lastWindowId == CGWindowID(9001))
    }

    @Test
    func `PID scoped focused element round trips through bridge`() async throws {
        let stub = await MainActor.run { StubServices() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: stub,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let request = PeekabooBridgeRequest.getFocusedElement(.init(targetProcessIdentifier: 4242))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)

        guard case let .focusedElement(info) = try self.decode(responseData) else {
            Issue.record("Expected focused-element response")
            return
        }
        #expect(info?.processId == 4242)
        #expect(info?.frame == CGRect(x: 100, y: 120, width: 300, height: 30))
        #expect(!PeekabooBridgeOperation.compatible(
            [.getFocusedElement],
            with: .init(major: 1, minor: 13)).contains(.getFocusedElement))
        #expect(PeekabooBridgeOperation.compatible(
            [.getFocusedElement],
            with: .init(major: 1, minor: 14)).contains(.getFocusedElement))
        let atomicKeyboard: Set<PeekabooBridgeOperation> = [
            .exactWindowTargetedTypeActions,
            .exactWindowTargetedHotkey,
        ]
        #expect(PeekabooBridgeOperation.compatible(
            atomicKeyboard,
            with: .init(major: 1, minor: 14)).isEmpty)
        #expect(PeekabooBridgeOperation.compatible(
            atomicKeyboard,
            with: .init(major: 1, minor: 16)).isEmpty)
        #expect(PeekabooBridgeOperation.compatible(
            atomicKeyboard,
            with: .init(major: 1, minor: 17)) == atomicKeyboard)
    }

    @Test
    func `automation click is forwarded`() async throws {
        let stub = await MainActor.run { StubServices() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: stub,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true })
        }

        let request = PeekabooBridgeRequest.click(
            PeekabooBridgeClickRequest(target: .elementId("B1"), clickType: .single, snapshotId: nil))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case .ok = response else {
            Issue.record("Expected ok response, got \(response)")
            return
        }

        let lastClick = await stub.automationStub.lastClick
        if case let .elementId(id)? = lastClick?.target {
            #expect(id == "B1")
        } else {
            Issue.record("Expected elementId(B1), got \(String(describing: lastClick?.target))")
        }
        #expect(lastClick?.type == .single)
    }

    @Test
    func `automation targeted hotkey is forwarded`() async throws {
        let stub = await MainActor.run { StubServices() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: stub,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true })
        }

        let request = PeekabooBridgeRequest.targetedHotkey(
            PeekabooBridgeTargetedHotkeyRequest(keys: "cmd,l", holdDuration: 50, targetProcessIdentifier: 9001))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case .ok = response else {
            Issue.record("Expected ok response, got \(response)")
            return
        }

        let lastHotkey = await stub.automationStub.lastProcessTargetedHotkey
        #expect(lastHotkey?.keys == "cmd,l")
        #expect(lastHotkey?.holdDuration == 50)
        #expect(lastHotkey?.targetProcessIdentifier == 9001)
        #expect(lastHotkey?.expectedProcessIdentity == nil)
    }

    @Test
    func `automation targeted hotkey forwards process-generation receipt`() async throws {
        let stub = await MainActor.run { StubServices() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: stub,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true })
        }
        let identity = ApplicationProcessIdentity(processIdentifier: 9001, processStartIdentity: 1234)
        let request = PeekabooBridgeRequest.targetedHotkey(.init(
            keys: "cmd,l",
            holdDuration: 50,
            targetProcessIdentifier: identity.processIdentifier,
            expectedProcessIdentity: identity))

        let response = try await self.decode(server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil))

        guard case .ok = response else {
            Issue.record("Expected ok response, got \(response)")
            return
        }
        let lastHotkey = await stub.automationStub.lastProcessTargetedHotkey
        #expect(lastHotkey?.expectedProcessIdentity == identity)
    }

    @Test
    func `legacy targeted hotkey payload decodes without process receipt`() throws {
        let data = Data(
            #"{"keys":"cmd,l","holdDuration":50,"targetProcessIdentifier":9001}"#.utf8)

        let payload = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeTargetedHotkeyRequest.self,
            from: data)

        #expect(payload.targetProcessIdentifier == 9001)
        #expect(payload.expectedProcessIdentity == nil)
    }

    @Test
    func `automation targeted type forwards process-generation receipt`() async throws {
        let stub = await MainActor.run { StubServices() }
        await MainActor.run {
            stub.automationStub.uiAutomationOutcomeScript.append(
                Self.eventTypingOutcome(characterCount: 5, mechanism: .processTargetedEvents),
                for: .typeActions)
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: stub,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in Self.inputPermissions },
                processStartIdentityProvider: { _ in 1235 })
        }
        let fixture = try await Self.startTrustedHost(server: server)
        defer { Task { await fixture.host.stop() } }
        let identity = ApplicationProcessIdentity(processIdentifier: 9010, processStartIdentity: 1235)
        let request = PeekabooBridgeRequest.targetedTypeActions(.init(
            actions: [.text("hello")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            targetProcessIdentifier: identity.processIdentifier,
            expectedProcessIdentity: identity))

        let response = try await fixture.client.send(request)

        guard case let .typeResult(result) = response else {
            Issue.record("Expected type result, got \(response)")
            return
        }
        #expect(result.totalCharacters == 5)
        #expect(result.keyPresses == 5)
        #expect(result.specialKeyPresses == 0)
        #expect(await stub.automationStub.lastProcessTargetedTypeIdentity == identity)
        try await Self.expectReceipt(
            client: fixture.client,
            handshake: fixture.handshake,
            operation: .targetedTypeActions,
            target: .process(identity))
        await fixture.host.stop()
    }

    @Test
    func `targeted type rejects mismatched process receipt before dispatch`() async throws {
        let stub = await MainActor.run { StubServices() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: stub,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in Self.inputPermissions },
                processStartIdentityProvider: { _ in 1235 })
        }
        let fixture = try await Self.startTrustedHost(server: server)
        defer { Task { await fixture.host.stop() } }
        let request = PeekabooBridgeRequest.targetedTypeActions(.init(
            actions: [.text("hello")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            targetProcessIdentifier: 9010,
            expectedProcessIdentity: .init(processIdentifier: 9011, processStartIdentity: 1235)))

        let reply = try await fixture.client.sendCarryingActionOutcome(request, throwsActionFailures: false)
        let response = reply.response

        guard case let .error(error) = response else {
            Issue.record("Expected error, got \(response)")
            return
        }
        #expect(error.code == .invalidRequest)
        #expect(error.actionOutcome?.state == .refused)
        #expect(error.actionOutcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(error.actionOutcome?.retrySafety == .safe)
        #expect(await stub.automationStub.lastProcessTargetedTypeIdentity == nil)
        #expect(await stub.automationStub.uiAutomationOutcomeScript.callCount(for: .typeActions) == 0)
        await fixture.host.stop()
    }

    @Test
    func `legacy targeted type payload decodes without process receipt`() throws {
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeTargetedTypeActionsRequest(
                actions: [],
                cadence: .fixed(milliseconds: 0),
                snapshotId: nil,
                targetProcessIdentifier: 9010))

        let payload = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeTargetedTypeActionsRequest.self,
            from: data)

        #expect(payload.targetProcessIdentifier == 9010)
        #expect(payload.expectedProcessIdentity == nil)
    }

    @Test
    func `automation targeted hotkey does not launch AppleScript probe`() async throws {
        let recorder = PermissionLaunchRecorder()
        let stub = await MainActor.run { StubServices() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: stub,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true },
                permissionStatusEvaluator: { allowAppleScriptLaunch in
                    recorder.status(allowAppleScriptLaunch: allowAppleScriptLaunch)
                })
        }

        let request = PeekabooBridgeRequest.targetedHotkey(
            PeekabooBridgeTargetedHotkeyRequest(keys: "cmd,l", holdDuration: 50, targetProcessIdentifier: 9001))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case .ok = response else {
            Issue.record("Expected ok response, got \(response)")
            return
        }

        #expect(!recorder.allowAppleScriptLaunchValues.contains(true))
    }

    @Test
    func `application launch does not trigger AppleScript permission probe`() async throws {
        let recorder = PermissionLaunchRecorder()
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true },
                permissionStatusEvaluator: { allowAppleScriptLaunch in
                    recorder.status(allowAppleScriptLaunch: allowAppleScriptLaunch)
                })
        }

        let request = PeekabooBridgeRequest.launchApplication(
            PeekabooBridgeAppIdentifierRequest(identifier: "StubApp"))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case .application = response else {
            Issue.record("Expected application response, got \(response)")
            return
        }

        #expect(!recorder.allowAppleScriptLaunchValues.contains(true))
    }

    @Test
    func `automation targeted hotkey is rejected without automation capability`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubNonTargetedServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }

        let request = PeekabooBridgeRequest.targetedHotkey(
            PeekabooBridgeTargetedHotkeyRequest(keys: "cmd,l", holdDuration: 50, targetProcessIdentifier: 9001))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .error(envelope) = response else {
            Issue.record("Expected error response, got \(response)")
            return
        }

        #expect(envelope.code == .operationNotSupported)
    }

    @Test
    func `automation invalid targeted hotkey returns invalid request`() async throws {
        let stub = await MainActor.run { StubServices() }
        await MainActor.run {
            stub.automationStub.targetedHotkeyError = PeekabooError.invalidInput("Unsupported background hotkey key")
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: stub,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true })
        }

        let request = PeekabooBridgeRequest.targetedHotkey(
            PeekabooBridgeTargetedHotkeyRequest(keys: "cmd,unknown", holdDuration: 50, targetProcessIdentifier: 9001))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .error(envelope) = response else {
            Issue.record("Expected error response, got \(response)")
            return
        }

        #expect(envelope.code == .invalidRequest)
        #expect(envelope.message == "Unsupported background hotkey key")
    }

    @Test
    func `automation targeted hotkey permission errors return permission denied`() async throws {
        let stub = await MainActor.run { StubServices() }
        await MainActor.run {
            stub.automationStub.targetedHotkeyError = PeekabooError.permissionDeniedAccessibility
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: stub,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true })
        }

        let request = PeekabooBridgeRequest.targetedHotkey(
            PeekabooBridgeTargetedHotkeyRequest(keys: "cmd,l", holdDuration: 50, targetProcessIdentifier: 9001))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .error(envelope) = response else {
            Issue.record("Expected error response, got \(response)")
            return
        }

        #expect(envelope.code == .permissionDenied)
        #expect(envelope.permission == .accessibility)
    }

    @Test
    func `automation targeted hotkey service unavailable returns operation not supported`() async throws {
        let stub = await MainActor.run { StubServices() }
        await MainActor.run {
            stub.automationStub.targetedHotkeyError = PeekabooError
                .serviceUnavailable("remote host does not support it")
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: stub,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true })
        }

        let request = PeekabooBridgeRequest.targetedHotkey(
            PeekabooBridgeTargetedHotkeyRequest(keys: "cmd,l", holdDuration: 50, targetProcessIdentifier: 9001))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .error(envelope) = response else {
            Issue.record("Expected error response, got \(response)")
            return
        }

        #expect(envelope.code == .operationNotSupported)
    }

    @Test
    func `targeted hotkey is disabled when post event access is missing`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { false })
        }

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)
        let handshakeRequest = PeekabooBridgeRequest.handshake(
            .init(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                client: identity,
                requestedHostKind: .gui))

        let handshakeData = try JSONEncoder.peekabooBridgeEncoder().encode(handshakeRequest)
        let handshakeResponseData = await server.decodeAndHandle(handshakeData, peer: nil)
        let handshakeResponse = try self.decode(handshakeResponseData)

        guard case let .handshake(handshake) = handshakeResponse else {
            Issue.record("Expected handshake response, got \(handshakeResponse)")
            return
        }

        #expect(handshake.supportedOperations.contains(.targetedHotkey))
        #expect(handshake.enabledOperations?.contains(.targetedHotkey) == false)
        let permissionTags = handshake.permissionTags[PeekabooBridgeOperation.targetedHotkey.rawValue]
        #expect(permissionTags == [.postEvent])

        let hotkeyRequest = PeekabooBridgeRequest.targetedHotkey(
            PeekabooBridgeTargetedHotkeyRequest(keys: "cmd,l", holdDuration: 50, targetProcessIdentifier: 9001))
        let hotkeyData = try JSONEncoder.peekabooBridgeEncoder().encode(hotkeyRequest)
        let hotkeyResponseData = await server.decodeAndHandle(hotkeyData, peer: nil)
        let hotkeyResponse = try self.decode(hotkeyResponseData)

        guard case let .error(envelope) = hotkeyResponse else {
            Issue.record("Expected error response, got \(hotkeyResponse)")
            return
        }

        #expect(envelope.code == .permissionDenied)
        #expect(envelope.permission == .postEvent)
    }
}

extension PeekabooBridgeTests {
    private static let remoteClientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peeka.cli",
        teamIdentifier: "TEAMID",
        processIdentifier: getpid())
    private static let legacyUnprojectedVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 22)
    private static let legacyProjectedVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 28)

    private static var inputPermissions: PermissionsStatus {
        PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
    }

    private static func eventTypingOutcome(
        characterCount: Int,
        mechanism: DesktopActionOutcome.Delivery.Mechanism) -> DesktopActionOutcome
    {
        .dispatchedUnverified(
            delivery: .init(mechanism: mechanism, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(characterCount))
    }

    private static func startTrustedHost(server: PeekabooBridgeServer) async throws
        -> (host: PeekabooBridgeHost, client: PeekabooBridgeClient, handshake: PeekabooBridgeHandshakeResponse)
    {
        let socketPath = "/tmp/peekaboo-ui-contract-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        do {
            let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
            let handshake = try await client.handshake(client: Self.remoteClientIdentity)
            return (host, client, handshake)
        } catch {
            await host.stop()
            throw error
        }
    }

    private static func expectReceipt(
        client: PeekabooBridgeClient,
        handshake: PeekabooBridgeHandshakeResponse,
        operation: PeekabooBridgeOperation,
        target: PeekabooBridgeOperationTargetReceipt) async throws
    {
        let bundle = try #require(await client.lastOperationReceiptBundle())
        let listener = try #require(handshake.operationAttestation)
        let session = try #require(handshake.operationSessionAttestation)
        try bundle.validate(trustAnchor: .listenerAttestation(listener))
        let receipt = bundle.receipt.payload
        #expect(receipt.operation == operation)
        #expect(receipt.target == target)
        #expect(receipt.sessionID == session.sessionID)
        #expect(receipt.clientInstanceID == session.clientInstanceID)
        #expect(receipt.client == session.client)
        #expect(receipt.requestID == PeekabooBridgeOperationReceiptCoding.deterministicRequestID(
            sessionID: session.sessionID,
            sequence: receipt.sessionSequence))
        #expect(receipt.selectedLeafEvidence == nil)
    }

    private static func negotiatedTrustedClient(
        socketPath: String,
        protocolVersion: PeekabooBridgeProtocolVersion = PeekabooBridgeConstants.protocolVersion) async throws
        -> PeekabooBridgeClient
    {
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.remoteClientIdentity, protocolVersion: protocolVersion)
        return client
    }

    @Test
    func `remote automation queries focus inside target PID`() async throws {
        let targetProcessIdentifier = getpid()
        let targetProcessGeneration = try #require(
            SystemIdentityResolver.processStartIdentity(targetProcessIdentifier))
        let socketPath = "/tmp/peekaboo-focused-element-\(UUID().uuidString).sock"
        let targetBounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let services = await MainActor.run { StubServices() }
        await MainActor.run {
            services.automationStub.uiAutomationOutcomeScript.append(
                Self.eventTypingOutcome(characterCount: 6, mechanism: .windowTargetedEvents),
                for: .typeActions)
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in Self.inputPermissions },
                windowOwnerProcessIdentifierProvider: { _ in targetProcessIdentifier },
                windowBoundsProvider: { _ in targetBounds },
                processStartIdentityProvider: { _ in targetProcessGeneration })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid()))
        #expect(handshake.supportedOperations.contains(.exactWindowTargetedTypeActions))
        #expect(handshake.supportedOperations.contains(.exactWindowTargetedHotkey))
        let supportsComposite = handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.compositeTypeDelivery) == true
        #expect(supportsComposite)
        let remote = await MainActor.run {
            RemoteUIAutomationService(
                client: client,
                supportsExactWindowTargetedKeyboard: true,
                supportsExactWindowCompositeTypeDelivery: supportsComposite)
        }

        let focused = await remote.getFocusedElement(targetProcessIdentifier: targetProcessIdentifier)
        let focusedIdentity = try #require(focused.flatMap(FocusedElementIdentity.init))
        let windowIdentity = WindowMutationIdentity(
            windowID: 999_999,
            ownerProcessIdentifier: targetProcessIdentifier,
            ownerProcessStartIdentity: targetProcessGeneration,
            capturedBounds: targetBounds)
        let result = try await remote.typeActions(
            [.text("atomic")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: "snapshot",
            target: ExactWindowKeyboardTarget(
                windowIdentity: windowIdentity,
                windowBounds: targetBounds,
                focusedElement: focusedIdentity))

        #expect(focused?.processId == Int(targetProcessIdentifier))
        #expect(focused?.applicationName == "Editor")
        #expect(result.totalCharacters == 6)
        #expect(result.keyPresses == 6)
        #expect(result.specialKeyPresses == 0)
        try await Self.expectReceipt(
            client: client,
            handshake: handshake,
            operation: .exactWindowTargetedTypeActions,
            target: .window(windowIdentity))
        #expect(await client.lastOperationReceipt()?.payload.focusedElement == focusedIdentity)
        await host.stop()
    }

    @Test
    func `atomic exact window keyboard blocks concurrent retarget request`() async throws {
        let socketPath = "/tmp/peekaboo-atomic-keyboard-\(UUID().uuidString).sock"
        let targetProcessIdentifier = getpid()
        let targetProcessGeneration = try #require(
            SystemIdentityResolver.processStartIdentity(targetProcessIdentifier))
        let targetBounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let services = await MainActor.run { StubServices() }
        await MainActor.run {
            services.automationStub.exactKeyboardDelayNanoseconds = 150_000_000
            services.automationStub.recordsExactKeyboardEvents = true
            services.automationStub.uiAutomationOutcomeScript.append(
                Self.eventTypingOutcome(characterCount: 6, mechanism: .windowTargetedEvents),
                for: .typeActions)
            services.automationStub.uiAutomationOutcomeScript.append(.dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one), for: .click)
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true },
                permissionStatusEvaluator: { _ in Self.inputPermissions },
                windowOwnerProcessIdentifierProvider: { _ in targetProcessIdentifier },
                windowBoundsProvider: { _ in targetBounds },
                processStartIdentityProvider: { _ in targetProcessGeneration })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let typeClient = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let clickClient = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let typeHandshake = try await typeClient.handshake(client: Self.remoteClientIdentity)
        let clickHandshake = try await clickClient.handshake(client: Self.remoteClientIdentity)
        let typeTask = Task {
            try await typeClient.typeActions(
                [.text("atomic")],
                cadence: .fixed(milliseconds: 0),
                snapshotId: "snapshot",
                expectedWindowIdentity: WindowMutationIdentity(
                    windowID: 999_999,
                    ownerProcessIdentifier: targetProcessIdentifier,
                    ownerProcessStartIdentity: targetProcessGeneration,
                    capturedBounds: targetBounds),
                expectedWindowBounds: targetBounds)
        }

        for _ in 0..<100 {
            let started = await MainActor.run {
                services.automationStub.exactKeyboardEvents.contains("type-start")
            }
            if started {
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let clickTask = Task {
            try await clickClient.click(
                target: .query("Sibling"),
                clickType: .single,
                snapshotId: "snapshot",
                expectedWindowIdentity: WindowMutationIdentity(
                    windowID: 888_888,
                    ownerProcessIdentifier: targetProcessIdentifier,
                    ownerProcessStartIdentity: targetProcessGeneration,
                    capturedBounds: targetBounds),
                expectedWindowBounds: targetBounds)
        }

        let typeResult = try await typeTask.value
        try await clickTask.value
        #expect(typeResult.totalCharacters == 6)
        #expect(typeResult.keyPresses == 6)
        let events = await MainActor.run { services.automationStub.exactKeyboardEvents }
        #expect(events == ["type-start", "type-end", "retarget"])
        for (client, handshake, operation, windowID) in [
            (typeClient, typeHandshake, PeekabooBridgeOperation.exactWindowTargetedTypeActions, 999_999),
            (clickClient, clickHandshake, PeekabooBridgeOperation.exactWindowTargetedClick, 888_888),
        ] {
            try await Self.expectReceipt(
                client: client,
                handshake: handshake,
                operation: operation,
                target: .window(.init(
                    windowID: windowID,
                    ownerProcessIdentifier: targetProcessIdentifier,
                    ownerProcessStartIdentity: targetProcessGeneration,
                    capturedBounds: targetBounds)))
        }
        let typeReceipt = try #require(await typeClient.lastOperationReceipt())
        let clickReceipt = try #require(await clickClient.lastOperationReceipt())
        #expect(typeReceipt.payload.requestID != clickReceipt.payload.requestID)
        #expect(typeReceipt.payload.sessionID != clickReceipt.payload.sessionID)
        #expect(typeReceipt.payload.clientInstanceID != clickReceipt.payload.clientInstanceID)
        await host.stop()
    }

    @Test
    func `remote targeted hotkey maps revoked post event permission`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-client-\(UUID().uuidString).sock"
        let postEventAccess = MutableBoolBox(true)
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: Self.legacyUnprojectedVersion...Self.legacyUnprojectedVersion,
                postEventAccessEvaluator: { postEventAccess.value })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)

        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(
            client: Self.remoteClientIdentity,
            protocolVersion: Self.legacyUnprojectedVersion)
        #expect(handshake.enabledOperations?.contains(.targetedHotkey) == true)

        postEventAccess.value = false
        let remote = await MainActor.run {
            RemoteUIAutomationService(client: client, supportsTargetedHotkeys: true)
        }

        do {
            try await remote.hotkey(keys: "cmd,l", holdDuration: 50, targetProcessIdentifier: getpid())
            Issue.record("Expected Event Synthesizing permission error")
        } catch PeekabooError.permissionDeniedEventSynthesizing {
            // Expected.
        }
    }

    @Test
    func `remote targeted hotkey preserves service permission failures conservatively`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-client-\(UUID().uuidString).sock"
        let stub = await MainActor.run { StubServices() }
        await MainActor.run {
            stub.automationStub.targetedHotkeyError = PeekabooError.permissionDeniedAccessibility
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: stub,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: Self.legacyUnprojectedVersion...Self.legacyUnprojectedVersion,
                postEventAccessEvaluator: { true })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)

        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = try await Self.negotiatedTrustedClient(
            socketPath: socketPath,
            protocolVersion: Self.legacyUnprojectedVersion)
        let remote = await MainActor.run {
            RemoteUIAutomationService(
                client: client,
                supportsTargetedHotkeys: true)
        }

        do {
            try await remote.hotkey(keys: "cmd,l", holdDuration: 50, targetProcessIdentifier: 9001)
            Issue.record("Expected Accessibility permission error")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.message == PeekabooError.permissionDeniedAccessibility.localizedDescription)
            #expect(failure.causeDescription?.contains("permissionDeniedAccessibility") == true)
        }
    }

    @Test
    func `remote targeted hotkey preserves post-dispatch invalid request conservatively`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-client-\(UUID().uuidString).sock"
        let stub = await MainActor.run { StubServices() }
        await MainActor.run {
            stub.automationStub.targetedHotkeyError = PeekabooError
                .invalidInput("Target process identifier is not running: 9001")
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: stub,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: Self.legacyUnprojectedVersion...Self.legacyUnprojectedVersion,
                postEventAccessEvaluator: { true })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)

        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = try await Self.negotiatedTrustedClient(
            socketPath: socketPath,
            protocolVersion: Self.legacyUnprojectedVersion)
        let remote = await MainActor.run {
            RemoteUIAutomationService(
                client: client,
                supportsTargetedHotkeys: true)
        }

        do {
            try await remote.hotkey(keys: "cmd,l", holdDuration: 50, targetProcessIdentifier: 9001)
            Issue.record("Expected invalid input error")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.message == "Target process identifier is not running: 9001")
            #expect(failure.causeDescription?.contains("invalidInput") == true)
        }
    }

    @Test
    func `remote targeted hotkey maps operation not supported envelope`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-client-\(UUID().uuidString).sock"
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubNonTargetedServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: Self.legacyUnprojectedVersion...Self.legacyUnprojectedVersion,
                postEventAccessEvaluator: { true })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)

        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = try await Self.negotiatedTrustedClient(
            socketPath: socketPath,
            protocolVersion: Self.legacyUnprojectedVersion)
        let remote = await MainActor.run {
            RemoteUIAutomationService(
                client: client,
                supportsTargetedHotkeys: true)
        }

        do {
            try await remote.hotkey(keys: "cmd,l", holdDuration: 50, targetProcessIdentifier: 9001)
            Issue.record("Expected service unavailable error")
        } catch let PeekabooError.serviceUnavailable(message) {
            #expect(message.contains("is not supported by this host"))
        }
    }

    @Test
    func `remote targeted and exact input conservatively adapt legacy indeterminate delivery errors`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-input-indeterminate-\(UUID().uuidString).sock"
        let targetedTypeFailure = Self.operationValidLegacyIndeterminateFailure(
            operation: .type,
            delivery: .processTargetedEvents,
            emittedUnitCount: 2,
            causeDescription: "targeted type destination drifted")
        let exactTypeFailure = Self.operationValidLegacyIndeterminateFailure(
            operation: .type,
            delivery: .windowTargetedEvents,
            emittedUnitCount: 3,
            causeDescription: "exact type destination drifted")
        let targetedHotkeyFailure = Self.operationValidLegacyIndeterminateFailure(
            operation: .hotkey,
            delivery: .processTargetedEvents,
            emittedUnitCount: 4,
            causeDescription: "targeted hotkey destination drifted")
        let exactHotkeyFailure = Self.operationValidLegacyIndeterminateFailure(
            operation: .hotkey,
            delivery: .windowTargetedEvents,
            emittedUnitCount: 5,
            causeDescription: "exact hotkey destination drifted")
        let clickFailure = Self.operationValidLegacyIndeterminateFailure(
            operation: .click,
            delivery: .windowTargetedEvents,
            emittedUnitCount: 3,
            causeDescription: "exact click destination drifted")
        let stub = await MainActor.run { StubServices() }
        await MainActor.run {
            stub.automationStub.targetedTypeError = targetedTypeFailure
            stub.automationStub.exactTypeError = exactTypeFailure
            stub.automationStub.targetedHotkeyError = targetedHotkeyFailure
            stub.automationStub.exactHotkeyError = exactHotkeyFailure
            stub.automationStub.targetedClickError = clickFailure
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: stub,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: Self.legacyProjectedVersion...Self.legacyProjectedVersion,
                postEventAccessEvaluator: { true },
                windowOwnerProcessIdentifierProvider: { _ in 4242 },
                windowBoundsProvider: { _ in CGRect(x: 0, y: 0, width: 800, height: 600) },
                processStartIdentityProvider: { _ in 1 })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)

        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = try await Self.negotiatedTrustedClient(
            socketPath: socketPath,
            protocolVersion: Self.legacyProjectedVersion)
        let remote = await MainActor.run {
            RemoteUIAutomationService(
                client: client,
                supportsTargetedHotkeys: true,
                supportsProcessGenerationPinnedHotkeys: true,
                supportsTargetedTypeActions: true,
                supportsProcessGenerationPinnedTypeActions: true,
                supportsTargetedClicks: true,
                supportsExactWindowTargetedClicks: true,
                supportsExactWindowTargetedKeyboard: true)
        }
        let expectedWindowIdentity = WindowMutationIdentity(
            windowID: 999_999,
            ownerProcessIdentifier: 4242,
            ownerProcessStartIdentity: 1,
            capturedBounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let expectedWindowBounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let expectedProcessIdentity = ApplicationProcessIdentity(
            processIdentifier: 4242,
            processStartIdentity: 1)

        try await Self.expectLegacyTextRefusals(
            client: client,
            processIdentity: expectedProcessIdentity,
            windowIdentity: expectedWindowIdentity,
            windowBounds: expectedWindowBounds)
        #expect(await stub.automationStub.uiAutomationOutcomeScript.callCount(for: .typeActions) == 0)

        do {
            try await remote.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: "snapshot",
                expectedWindowIdentity: expectedWindowIdentity,
                expectedWindowBounds: expectedWindowBounds)
            Issue.record("Expected exact click outcome to be indeterminate")
        } catch let failure as DesktopActionFailure {
            Self.expectLegacyIndeterminateFailure(failure, expected: clickFailure)
        } catch {
            Issue.record("Expected exact click indeterminate error, got \(error)")
        }

        do {
            _ = try await remote.typeActions(
                [.key(.return), .key(.tab)],
                cadence: .fixed(milliseconds: 0),
                snapshotId: "snapshot",
                expectedProcessIdentity: expectedProcessIdentity)
            Issue.record("Expected targeted type outcome to be indeterminate")
        } catch let failure as DesktopActionFailure {
            Self.expectLegacyIndeterminateFailure(failure, expected: targetedTypeFailure)
        } catch {
            Issue.record("Expected targeted type indeterminate error, got \(error)")
        }

        do {
            _ = try await remote.typeActions(
                [.key(.return), .key(.tab), .key(.escape)],
                cadence: .fixed(milliseconds: 0),
                snapshotId: "snapshot",
                expectedWindowIdentity: expectedWindowIdentity,
                expectedWindowBounds: expectedWindowBounds)
            Issue.record("Expected exact type outcome to be indeterminate")
        } catch let failure as DesktopActionFailure {
            Self.expectLegacyIndeterminateFailure(failure, expected: exactTypeFailure)
        } catch {
            Issue.record("Expected exact type indeterminate error, got \(error)")
        }

        do {
            try await remote.hotkey(
                keys: "cmd,l",
                holdDuration: 50,
                expectedProcessIdentity: expectedProcessIdentity)
            Issue.record("Expected targeted hotkey outcome to be indeterminate")
        } catch let failure as DesktopActionFailure {
            Self.expectLegacyIndeterminateFailure(failure, expected: targetedHotkeyFailure)
        } catch {
            Issue.record("Expected targeted hotkey indeterminate error, got \(error)")
        }

        do {
            try await remote.hotkey(
                keys: "cmd,l",
                holdDuration: 50,
                expectedWindowIdentity: expectedWindowIdentity,
                expectedWindowBounds: expectedWindowBounds)
            Issue.record("Expected exact hotkey outcome to be indeterminate")
        } catch let failure as DesktopActionFailure {
            Self.expectLegacyIndeterminateFailure(failure, expected: exactHotkeyFailure)
        } catch {
            Issue.record("Expected exact hotkey indeterminate error, got \(error)")
        }
        #expect(await stub.automationStub.uiAutomationOutcomeScript.callCount(for: .typeActions) == 2)
        #expect(await client.lastOperationReceipt() == nil)
        await host.stop()
    }

    private static func operationValidLegacyIndeterminateFailure(
        operation: InputDeliveryIndeterminateError.Operation,
        delivery: DesktopActionOutcome.Delivery.Mechanism,
        emittedUnitCount: Int,
        causeDescription: String) -> DesktopActionFailure
    {
        let source = InputDeliveryIndeterminateError(
            operation: operation,
            emittedUnitCount: emittedUnitCount,
            causeDescription: causeDescription)
        return DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: delivery, mode: .background),
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(emittedUnitCount),
            message: source.localizedDescription,
            hint: "Observe the target before taking another action.",
            causeDescription: causeDescription)
    }

    private static func expectLegacyIndeterminateFailure(
        _ failure: DesktopActionFailure,
        expected: DesktopActionFailure)
    {
        #expect(failure == expected.routed(to: .bridge))
    }

    private static func expectLegacyTextRefusals(
        client: PeekabooBridgeClient,
        processIdentity: ApplicationProcessIdentity,
        windowIdentity: WindowMutationIdentity,
        windowBounds: CGRect) async throws
    {
        // Protocol 1.28 can still deliver event-only keys, but cannot attest AX-capable typing.
        let textRequests: [PeekabooBridgeRequest] = [
            .targetedTypeActions(.init(
                actions: [.text("targeted")],
                cadence: .fixed(milliseconds: 0),
                snapshotId: "snapshot",
                targetProcessIdentifier: processIdentity.processIdentifier,
                expectedProcessIdentity: processIdentity)),
            .exactWindowTargetedTypeActions(.init(
                actions: [.text("exact")],
                cadence: .fixed(milliseconds: 0),
                snapshotId: "snapshot",
                expectedWindowIdentity: windowIdentity,
                expectedWindowBounds: windowBounds,
                expectedFocusedElement: nil)),
        ]
        for request in textRequests {
            let failure = await #expect(throws: DesktopActionFailure.self) {
                _ = try await client.send(request)
            }
            #expect(failure?.outcome.state == .refused)
            #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
            #expect(failure?.outcome.retrySafety == .safe)
            #expect(failure?.outcome.refusalReason == .runtimeIncompatible)
        }
    }

    @Test
    @MainActor
    func `remote services expose element actions only when handshake supports them`() {
        let client = PeekabooBridgeClient(
            socketPath: "/tmp/nonexistent-\(UUID().uuidString).sock",
            requestTimeoutSec: 1)

        let unsupported = RemotePeekabooServices(client: client, supportsElementActions: false)
        let actionOnly = RemotePeekabooServices(client: client, supportsElementActions: true)
        let supported = RemotePeekabooServices(
            client: client,
            supportsElementActions: true,
            supportsSetValueResultTargetBinding: true)

        #expect((unsupported.automation as? any ElementActionAutomationServiceProtocol) == nil)
        #expect((actionOnly.automation as? any ElementActionAutomationServiceProtocol)?
            .supportsSetValueResultTargetBinding == false)
        #expect((supported.automation as? any ElementActionAutomationServiceProtocol)?
            .supportsSetValueResultTargetBinding == true)
    }

    @Test
    func `bridge setValue forwards to automation service`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-set-value-\(UUID().uuidString).sock"
        let services = await MainActor.run { StubServices() }
        let processGeneration = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        await MainActor.run {
            services.automationStub.actionOutcome = .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one)
            services.automationStub.uiAutomationOutcomeTargetIdentity = try? DesktopTargetIdentity(
                processIdentity: .init(
                    processIdentifier: getpid(),
                    processStartIdentity: processGeneration))
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)

        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = try await Self.negotiatedTrustedClient(socketPath: socketPath)
        let remote = await MainActor.run {
            RemoteElementActionUIAutomationService(
                client: client)
        }
        let result = try await remote.setValue(
            target: "T1",
            value: .string("hello"),
            snapshotId: SnapshotReferenceFixtures.first.rawValue)

        #expect(result.target == "T1")
        let call = await MainActor.run { services.automationStub.lastSetValue }
        #expect(call?.target == "T1")
        #expect(call?.value == .string("hello"))
        #expect(call?.snapshotId == SnapshotReferenceFixtures.first.rawValue)
    }

    @Test
    func `bridge performAction forwards to automation service`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-perform-action-\(UUID().uuidString).sock"
        let services = await MainActor.run { StubServices() }
        let processGeneration = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        await MainActor.run {
            services.automationStub.actionOutcome = .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one)
            services.automationStub.uiAutomationOutcomeTargetIdentity = try? DesktopTargetIdentity(
                processIdentity: .init(
                    processIdentifier: getpid(),
                    processStartIdentity: processGeneration))
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)

        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = try await Self.negotiatedTrustedClient(socketPath: socketPath)
        let remote = await MainActor.run {
            RemoteElementActionUIAutomationService(
                client: client)
        }
        let result = try await remote.performAction(
            target: "B1",
            actionName: "AXPress",
            snapshotId: SnapshotReferenceFixtures.first.rawValue)

        #expect(result.actionName == "AXPress")
        let call = await MainActor.run { services.automationStub.lastPerformAction }
        #expect(call?.target == "B1")
        #expect(call?.actionName == "AXPress")
        #expect(call?.snapshotId == SnapshotReferenceFixtures.first.rawValue)
    }

    @Test
    func `legacy snapshot click failures stay indeterminate and element actions refuse before dispatch`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-snapshot-actions-\(UUID().uuidString).sock"
        let services = await MainActor.run { StubServices() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: Self.legacyUnprojectedVersion...Self.legacyUnprojectedVersion,
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: true,
                        appleScript: false,
                        postEvent: true)
                })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = try await Self.negotiatedTrustedClient(
            socketPath: socketPath,
            protocolVersion: Self.legacyUnprojectedVersion)
        let remote = await MainActor.run { RemoteUIAutomationService(client: client) }
        await MainActor.run {
            services.automationStub.clickError = PeekabooError.snapshotStale("window moved")
        }
        do {
            try await remote.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: SnapshotReferenceFixtures.first.rawValue)
            Issue.record("Expected stale snapshot error")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.message.contains("window moved"))
            #expect(failure.causeDescription?.contains("snapshotStale") == true)
        }

        let elementActions = await MainActor.run { RemoteElementActionUIAutomationService(client: client) }
        await MainActor.run {
            services.automationStub.elementActionError = PeekabooError.snapshotNotFound("expired")
        }
        do {
            _ = try await elementActions.setValue(
                target: "T1",
                value: .string("hello"),
                snapshotId: SnapshotReferenceFixtures.first.rawValue)
            Issue.record("Expected legacy set-value refusal before snapshot lookup")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.message.contains("setValue requires an attested exact-target result"))
            #expect(failure.causeDescription == nil)
        }

        await MainActor.run {
            services.automationStub.elementActionError = PeekabooError.elementNotFound("B404")
        }
        do {
            _ = try await elementActions.performAction(
                target: "B404",
                actionName: "AXPress",
                snapshotId: SnapshotReferenceFixtures.first.rawValue)
            Issue.record("Expected legacy perform-action refusal before element lookup")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.message.contains("performAction requires an attested exact-target result"))
            #expect(failure.causeDescription == nil)
        }
        #expect(await services.automationStub.uiAutomationOutcomeScript.callCount(for: .setValue) == 0)
        #expect(await services.automationStub.uiAutomationOutcomeScript.callCount(for: .performAction) == 0)
        #expect(await services.automationStub.lastSetValue == nil)
        #expect(await services.automationStub.lastPerformAction == nil)
        await host.stop()
    }

    @Test
    func `unsupported remote automation capabilities are not advertised`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubRemoteAutomationServices(supportsTargetedHotkeys: false),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)

        let request = PeekabooBridgeRequest.handshake(
            .init(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                client: identity,
                requestedHostKind: .gui))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .handshake(handshake) = response else {
            Issue.record("Expected handshake response, got \(response)")
            return
        }

        #expect(!handshake.supportedOperations.contains(.targetedHotkey))
        #expect(!handshake.supportedOperations.contains(.exactWindowTargetedClick))
    }
}

// MARK: - Test stubs

@MainActor
final class StubServices: PeekabooBridgeServiceProviding {
    let screenCaptureStub = StubScreenCaptureService()
    let screenCapture: any ScreenCaptureServiceProtocol
    let automationStub = StubAutomationService()
    let automation: any UIAutomationServiceProtocol
    let applications: any ApplicationServiceProtocol
    let windows: any WindowManagementServiceProtocol
    let menu: any MenuServiceProtocol = UnimplementedMenuService()
    let dock: any DockServiceProtocol = UnimplementedDockService()
    let dialogs: any DialogServiceProtocol = UnimplementedDialogService()
    let snapshots: any SnapshotManagerProtocol
    let desktopObservationStub: StubDesktopObservationService
    let desktopObservation: any DesktopObservationServiceProtocol
    let permissions: PermissionsService = .init()
    let supportsScreenCaptureKitProcessOwnership: Bool
    var lastBrowserStatusChannel: String?
    var lastBrowserConnectTarget: (channel: String?, browserURL: String?)?
    var lastBrowserExecute: PeekabooBridgeBrowserExecuteRequest?
    var lastExpectedBrowserConnectionReceipt: PeekabooBridgeBrowserConnectionReceipt?
    var browserActionFailure: DesktopActionFailure?
    var browserRawIsError = false
    var browserResponseStructuredContent: PeekabooBridgeJSONValue?
    var browserStatusError: (any Error)?
    var browserConnectFailure: DesktopActionFailure?
    var browserConnectError: (any Error)?
    var browserConnectOutcome = DesktopActionOutcome.dispatchedUnverified(
        delivery: .init(mechanism: .browserProtocol, mode: .foreground),
        evidence: .deliveryAccepted,
        unitCount: .one)
    var browserExecutionError: (any Error)?
    var browserExecutionErrorAfterDispatch: (any Error)?
    var browserExecutionReceiptOverride: PeekabooBridgeBrowserConnectionReceipt?
    var browserCompletedCallCount: Int?
    var browserDispatchedCallCount: Int?
    var preservesBrowserReceiptChannel = false
    private let ownedDesktopOperationLanes: Set<PeekabooBridgeOperation>
    var browserResponseContent: [PeekabooBridgeJSONValue] = [
        .object([
            "type": .string("text"),
            "text": .string("ok"),
        ]),
    ]
    var browserConnectionReceipt = PeekabooBridgeBrowserConnectionReceipt(
        channel: "stable",
        processIdentifier: 42,
        processStartIdentity: 10042,
        bundleIdentifier: "com.google.Chrome",
        browserURL: "http://127.0.0.1:9222/",
        webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
        devToolsBrowserID: "browser-a",
        browserVersion: "Chrome/144.0",
        protocolVersion: "1.3")

    init(
        applications: any ApplicationServiceProtocol = StubApplicationService(),
        automation: (any UIAutomationServiceProtocol)? = nil,
        windows: any WindowManagementServiceProtocol = makeStubWindowService(),
        snapshots: any SnapshotManagerProtocol = SnapshotManager(),
        desktopObservation: (any DesktopObservationServiceProtocol)? = nil,
        ownedDesktopOperationLanes: Set<PeekabooBridgeOperation> = [],
        supportsScreenCaptureKitProcessOwnership: Bool = false)
    {
        let desktopObservationStub = StubDesktopObservationService()
        self.screenCapture = self.screenCaptureStub
        self.automation = automation ?? self.automationStub
        self.applications = applications
        self.windows = windows
        self.snapshots = snapshots
        self.desktopObservationStub = desktopObservationStub
        self.desktopObservation = desktopObservation ?? desktopObservationStub
        self.ownedDesktopOperationLanes = ownedDesktopOperationLanes
        self.supportsScreenCaptureKitProcessOwnership = supportsScreenCaptureKitProcessOwnership
    }

    func ownsDesktopOperationLane(for operation: PeekabooBridgeOperation) -> Bool {
        self.ownedDesktopOperationLanes.contains(operation)
    }

    func browserStatus(channel: String?) async throws -> PeekabooBridgeBrowserStatus {
        if let browserStatusError {
            throw browserStatusError
        }
        self.lastBrowserStatusChannel = channel
        let resolvedChannel = channel ?? "stable"
        return PeekabooBridgeBrowserStatus(
            isConnected: true,
            toolCount: 1,
            detectedBrowsers: [
                PeekabooBridgeBrowserInfo(
                    name: "Google Chrome",
                    bundleIdentifier: "com.google.Chrome",
                    processIdentifier: 42,
                    version: "144.0",
                    channel: resolvedChannel),
            ],
            connectionReceipt: self.preservesBrowserReceiptChannel ||
                self.browserConnectionReceipt.channel == resolvedChannel
                ? self.browserConnectionReceipt
                : PeekabooBridgeBrowserConnectionReceipt(
                    channel: resolvedChannel,
                    processIdentifier: self.browserConnectionReceipt.processIdentifier,
                    processStartIdentity: self.browserConnectionReceipt.processStartIdentity,
                    bundleIdentifier: self.browserConnectionReceipt.bundleIdentifier,
                    browserURL: self.browserConnectionReceipt.browserURL,
                    webSocketDebuggerURL: self.browserConnectionReceipt.webSocketDebuggerURL,
                    devToolsBrowserID: self.browserConnectionReceipt.devToolsBrowserID,
                    browserVersion: self.browserConnectionReceipt.browserVersion,
                    protocolVersion: self.browserConnectionReceipt.protocolVersion))
    }

    func browserConnect(channel: String?, browserURL: String?) async throws -> PeekabooBridgeBrowserStatus {
        self.lastBrowserConnectTarget = (channel, browserURL)
        return try await self.browserStatus(channel: channel)
    }

    func browserExecute(_ request: PeekabooBridgeBrowserExecuteRequest) async throws
    -> PeekabooBridgeBrowserToolResponse {
        self.lastBrowserExecute = request
        return PeekabooBridgeBrowserToolResponse(
            content: self.browserResponseContent,
            isError: self.browserRawIsError,
            meta: nil,
            structuredContent: self.browserResponseStructuredContent)
    }

    func browserExecute(
        _ request: PeekabooBridgeBrowserExecuteRequest,
        expectedConnectionReceipt: PeekabooBridgeBrowserConnectionReceipt) async throws
        -> PeekabooBridgeBrowserExecutionResult
    {
        if let browserExecutionError {
            throw browserExecutionError
        }
        self.lastExpectedBrowserConnectionReceipt = expectedConnectionReceipt
        let response = try await self.browserExecute(request)
        if let browserExecutionErrorAfterDispatch {
            throw browserExecutionErrorAfterDispatch
        }
        let actionFailure = self.browserActionFailure
        return PeekabooBridgeBrowserExecutionResult(
            response: PeekabooBridgeBrowserToolResponse(
                content: response.content,
                isError: actionFailure != nil || response.isError,
                meta: response.meta,
                structuredContent: response.structuredContent),
            connectionReceipt: self.browserExecutionReceiptOverride ?? expectedConnectionReceipt,
            completedCallCount: self.browserCompletedCallCount ?? request.resolvedCalls.count,
            dispatchedCallCount: self.browserDispatchedCallCount ?? request.resolvedCalls.count,
            actionFailure: actionFailure)
    }
}

@MainActor
private final class StubNonTargetedServices: PeekabooBridgeServiceProviding {
    let screenCapture: any ScreenCaptureServiceProtocol = StubScreenCaptureService()
    let automation: any UIAutomationServiceProtocol = StubNonTargetedAutomationService()
    let applications: any ApplicationServiceProtocol = StubApplicationService()
    let windows: any WindowManagementServiceProtocol = makeStubWindowService()
    let menu: any MenuServiceProtocol = UnimplementedMenuService()
    let dock: any DockServiceProtocol = UnimplementedDockService()
    let dialogs: any DialogServiceProtocol = UnimplementedDialogService()
    let snapshots: any SnapshotManagerProtocol = SnapshotManager()
    let desktopObservation: any DesktopObservationServiceProtocol = StubDesktopObservationService()
    let permissions: PermissionsService = .init()
}

@MainActor
private final class StubRemoteAutomationServices: PeekabooBridgeServiceProviding {
    let screenCapture: any ScreenCaptureServiceProtocol = StubScreenCaptureService()
    let automation: any UIAutomationServiceProtocol
    let applications: any ApplicationServiceProtocol = StubApplicationService()
    let windows: any WindowManagementServiceProtocol = makeStubWindowService()
    let menu: any MenuServiceProtocol = UnimplementedMenuService()
    let dock: any DockServiceProtocol = UnimplementedDockService()
    let dialogs: any DialogServiceProtocol = UnimplementedDialogService()
    let snapshots: any SnapshotManagerProtocol = SnapshotManager()
    let desktopObservation: any DesktopObservationServiceProtocol = StubDesktopObservationService()
    let permissions: PermissionsService = .init()

    init(supportsTargetedHotkeys: Bool) {
        self.automation = RemoteUIAutomationService(
            client: PeekabooBridgeClient(socketPath: "/tmp/peekaboo-unused.sock"),
            supportsTargetedHotkeys: supportsTargetedHotkeys)
    }
}

@MainActor
final class StubDesktopObservationService: DesktopObservationServiceProtocol {
    private(set) var lastRequest: DesktopObservationRequest?

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.lastRequest = request
        let outputPath = request.output.saveRawScreenshot ? request.output.path : nil
        return DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: StubScreenCaptureService.sampleData,
                savedPath: outputPath,
                metadata: CaptureMetadata(
                    size: .init(width: 1, height: 1),
                    mode: .screen,
                    timestamp: Date())),
            elements: nil,
            files: DesktopObservationFiles(rawScreenshotPath: outputPath))
    }
}

final class StubScreenCaptureService: ScreenCaptureServiceProtocol {
    static let sampleData = Data("stub-capture".utf8)
    private(set) var lastWindowId: CGWindowID?

    func captureScreen(
        displayIndex: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        _ = (displayIndex, visualizerMode, scale)
        return self.makeResult(mode: .screen)
    }

    func captureWindow(
        appIdentifier: String,
        windowIndex: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        _ = (appIdentifier, windowIndex, visualizerMode, scale)
        self.lastWindowId = nil
        return self.makeResult(mode: .window)
    }

    func captureWindow(
        windowID: CGWindowID,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        _ = (visualizerMode, scale)
        self.lastWindowId = windowID
        return self.makeResult(mode: .window)
    }

    func captureFrontmost(
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        _ = (visualizerMode, scale)
        return self.makeResult(mode: .frontmost)
    }

    func captureArea(
        _ rect: CGRect,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        _ = (rect, visualizerMode, scale)
        return self.makeResult(mode: .area)
    }

    func hasScreenRecordingPermission() async -> Bool {
        true
    }

    private func makeResult(mode: CaptureMode) -> CaptureResult {
        CaptureResult(
            imageData: Self.sampleData,
            savedPath: nil,
            metadata: CaptureMetadata(
                size: .init(width: 1, height: 1),
                mode: mode,
                timestamp: Date()))
    }
}

@MainActor
class StubAutomationService: TargetedHotkeyServiceProtocol, TargetedTypeServiceProtocol,
    ExactWindowTargetedClickServiceProtocol,
    ElementActionAutomationServiceProtocol, TargetedFocusedElementServiceProtocol,
    ExactWindowTargetedKeyboardServiceProtocol
{
    var supportsSetValueResultTargetBinding = true
    var supportsProcessGenerationBoundElementMutations = true
    var dragError: (any Error)?
    let supportsProcessGenerationPinnedHotkeys = true
    let supportsProcessGenerationPinnedTypeActions = true
    let supportsProcessGenerationPinnedClicks = true
    let supportsStatelessClickVariants = true
    let supportsExactWindowTargetedKeyboard = true
    var supportsExactWindowCompositeTypeDelivery: Bool {
        true
    }

    let exactWindowTargetedKeyboardUnavailableReason: String? = nil
    struct Click { let target: ClickTarget; let type: ClickType }
    struct TargetedHotkey {
        let keys: String
        let holdDuration: Int
        let targetProcessIdentifier: pid_t?
        let expectedProcessIdentity: ApplicationProcessIdentity?
    }

    struct TargetedClick {
        let target: ClickTarget
        let type: ClickType
        let targetProcessIdentifier: pid_t?
        let targetWindowID: Int?
        let expectedProcessIdentity: ApplicationProcessIdentity?
    }

    struct SetValue {
        let target: String
        let value: UIElementValue
        let snapshotId: String?
    }

    struct PerformAction {
        let target: String
        let actionName: String
        let snapshotId: String?
    }

    func getFocusedElement(targetProcessIdentifier: pid_t) async -> UIFocusInfo? {
        UIFocusInfo(
            role: "AXTextField",
            title: "Editor",
            value: nil,
            frame: CGRect(x: 100, y: 120, width: 300, height: 30),
            applicationName: "Editor",
            bundleIdentifier: "com.example.editor",
            processId: Int(targetProcessIdentifier),
            windowID: 999_999)
    }

    private(set) var lastClick: Click?
    private(set) var lastProcessTargetedHotkey: TargetedHotkey?
    private(set) var lastProcessTargetedClick: TargetedClick?
    private(set) var lastAllowsAccessibilityValueDelivery: Bool?
    private(set) var lastProcessTargetedTypeIdentity: ApplicationProcessIdentity?
    private(set) var lastTypeActions: [TypeAction]?
    private(set) var lastSetValue: SetValue?
    private(set) var lastPerformAction: PerformAction?
    var clickError: (any Error)?
    var elementActionError: (any Error)?
    var targetedTypeError: (any Error)?
    var targetedHotkeyError: (any Error)?
    var exactTypeError: (any Error)?
    var exactHotkeyError: (any Error)?
    var targetedClickError: (any Error)?
    var supportsTargetedClickAccessibilityValueDelivery = false
    private static let defaultActionOutcome = DesktopActionOutcome.dispatchedUnverified(
        delivery: .init(mechanism: .accessibilityAction, mode: .background),
        evidence: .deliveryAccepted)
    let uiAutomationOutcomeScript = UIAutomationOutcomeScript(
        defaultResponse: .outcome(StubAutomationService.defaultActionOutcome))
    var uiAutomationOutcomeTargetIdentity: DesktopTargetIdentity?
    var supportsRequestPinnedExactWindowScrollReceipt = true
    var allowsContradictoryOutcomeTargetIdentityForTesting = false
    var actionOutcome = StubAutomationService.defaultActionOutcome {
        didSet {
            self.uiAutomationOutcomeScript.setDefaultOutcome(self.actionOutcome)
        }
    }

    var exactKeyboardDelayNanoseconds: UInt64 = 0
    var recordsExactKeyboardEvents = false
    private(set) var exactKeyboardEvents: [String] = []

    func detectElements(in _: Data, snapshotId _: String?, windowContext _: WindowContext?) async throws
        -> ElementDetectionResult
    {
        ElementDetectionResult(
            snapshotId: "s",
            screenshotPath: "/tmp/s.png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: "stub",
                warnings: [],
                windowContext: nil,
                isDialog: false))
    }

    func click(target: ClickTarget, clickType: ClickType, snapshotId _: String?) async throws {
        if let clickError {
            throw clickError
        }
        self.lastClick = Click(target: target, type: clickType)
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId _: String?,
        targetProcessIdentifier: pid_t) async throws
    {
        if let targetedClickError {
            throw targetedClickError
        }
        self.lastProcessTargetedClick = TargetedClick(
            target: target,
            type: clickType,
            targetProcessIdentifier: targetProcessIdentifier,
            targetWindowID: nil,
            expectedProcessIdentity: nil)
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId _: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws
    {
        if let targetedClickError {
            throw targetedClickError
        }
        self.lastProcessTargetedClick = TargetedClick(
            target: target,
            type: clickType,
            targetProcessIdentifier: expectedProcessIdentity.processIdentifier,
            targetWindowID: nil,
            expectedProcessIdentity: expectedProcessIdentity)
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity,
        allowsAccessibilityValueDelivery: Bool) async throws
    {
        self.lastAllowsAccessibilityValueDelivery = allowsAccessibilityValueDelivery
        try await self.click(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedProcessIdentity: expectedProcessIdentity)
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId _: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds _: CGRect) async throws
    {
        if let targetedClickError {
            throw targetedClickError
        }
        self.lastProcessTargetedClick = TargetedClick(
            target: target,
            type: clickType,
            targetProcessIdentifier: expectedWindowIdentity.ownerProcessIdentifier,
            targetWindowID: expectedWindowIdentity.windowID,
            expectedProcessIdentity: ApplicationProcessIdentity(
                processIdentifier: expectedWindowIdentity.ownerProcessIdentifier,
                processStartIdentity: expectedWindowIdentity.ownerProcessStartIdentity))
        if self.recordsExactKeyboardEvents {
            self.exactKeyboardEvents.append("retarget")
        }
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        windowEvidence: ExactWindowClickEvidence,
        allowsAccessibilityValueDelivery: Bool) async throws
    {
        self.lastAllowsAccessibilityValueDelivery = allowsAccessibilityValueDelivery
        try await self.click(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedWindowIdentity: windowEvidence.identity,
            expectedWindowBounds: windowEvidence.bounds)
    }

    func type(text _: String, target _: String?, clearExisting _: Bool, typingDelay _: Int, snapshotId _: String?) async
    throws {}

    func typeActions(_ actions: [TypeAction], cadence _: TypingCadence, snapshotId _: String?) async throws
        -> TypeResult
    {
        self.lastTypeActions = actions
        return BridgeTestFixtures.typeResult(for: actions)
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        targetProcessIdentifier _: pid_t) async throws -> TypeResult
    {
        if let targetedTypeError {
            throw targetedTypeError
        }
        return BridgeTestFixtures.typeResult(for: actions)
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> TypeResult
    {
        if let targetedTypeError {
            throw targetedTypeError
        }
        self.lastProcessTargetedTypeIdentity = expectedProcessIdentity
        return BridgeTestFixtures.typeResult(for: actions)
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds _: CGRect) async throws -> TypeResult
    {
        if let exactTypeError {
            throw exactTypeError
        }
        guard expectedWindowIdentity.windowID == 999_999 else {
            throw PeekabooError.invalidInput("exact window mismatch")
        }
        self.exactKeyboardEvents.append("type-start")
        if self.exactKeyboardDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: self.exactKeyboardDelayNanoseconds)
        }
        self.exactKeyboardEvents.append("type-end")
        return BridgeTestFixtures.typeResult(for: actions)
    }

    func hotkey(
        keys _: String,
        holdDuration _: Int,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds _: CGRect) async throws
    {
        if let exactHotkeyError {
            throw exactHotkeyError
        }
        guard expectedWindowIdentity.windowID == 999_999 else {
            throw PeekabooError.invalidInput("exact window mismatch")
        }
        self.exactKeyboardEvents.append("hotkey")
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        target: ExactWindowKeyboardTarget) async throws -> TypeResult
    {
        guard target.focusedElement.processIdentifier == target.windowIdentity.ownerProcessIdentifier,
              target.focusedElement.windowID == target.windowIdentity.windowID
        else {
            throw PeekabooError.invalidInput("focused destination mismatch")
        }
        return try await self.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            expectedWindowIdentity: target.windowIdentity,
            expectedWindowBounds: target.windowBounds)
    }

    func hotkey(
        keys: String,
        holdDuration: Int,
        target: ExactWindowKeyboardTarget) async throws
    {
        guard target.focusedElement.processIdentifier == target.windowIdentity.ownerProcessIdentifier,
              target.focusedElement.windowID == target.windowIdentity.windowID
        else {
            throw PeekabooError.invalidInput("focused destination mismatch")
        }
        try await self.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            expectedWindowIdentity: target.windowIdentity,
            expectedWindowBounds: target.windowBounds)
    }

    func setValue(target: String, value: UIElementValue, snapshotId: String?) async throws -> ElementActionResult {
        if let elementActionError {
            throw elementActionError
        }
        self.lastSetValue = SetValue(target: target, value: value, snapshotId: snapshotId)
        return ElementActionResult(
            target: target,
            actionName: "AXSetValue",
            anchorPoint: nil,
            newValue: value.displayString)
    }

    func performAction(target: String, actionName: String, snapshotId: String?) async throws -> ElementActionResult {
        if let elementActionError {
            throw elementActionError
        }
        self.lastPerformAction = PerformAction(target: target, actionName: actionName, snapshotId: snapshotId)
        return ElementActionResult(target: target, actionName: actionName, anchorPoint: nil)
    }

    func scroll(_ request: ScrollRequest) async throws {
        _ = request
    }

    func hotkey(keys _: String, holdDuration _: Int) async throws {}

    func hotkey(keys: String, holdDuration: Int, targetProcessIdentifier: pid_t) async throws {
        if let targetedHotkeyError {
            throw targetedHotkeyError
        }

        self.lastProcessTargetedHotkey = TargetedHotkey(
            keys: keys,
            holdDuration: holdDuration,
            targetProcessIdentifier: targetProcessIdentifier,
            expectedProcessIdentity: nil)
    }

    func hotkey(
        keys: String,
        holdDuration: Int,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws
    {
        if let targetedHotkeyError {
            throw targetedHotkeyError
        }

        self.lastProcessTargetedHotkey = TargetedHotkey(
            keys: keys,
            holdDuration: holdDuration,
            targetProcessIdentifier: expectedProcessIdentity.processIdentifier,
            expectedProcessIdentity: expectedProcessIdentity)
    }

    func swipe(from _: CGPoint, to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile) async
    throws {}

    func hasAccessibilityPermission() async -> Bool {
        true
    }

    func waitForElement(target _: ClickTarget, timeout _: TimeInterval, snapshotId _: String?) async throws
        -> WaitForElementResult
    {
        WaitForElementResult(found: true, element: nil, waitTime: 0)
    }

    func drag(_: DragOperationRequest) async throws {
        if let dragError {
            throw dragError
        }
    }

    func moveMouse(to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile) async throws {}

    func getFocusedElement() -> UIFocusInfo? {
        nil
    }

    func findElement(matching _: UIElementSearchCriteria, in _: String?) async throws -> DetectedElement {
        throw PeekabooError.operationError(message: "stub")
    }
}

@MainActor
final class StubNonTargetedAutomationService: UIAutomationServiceProtocol {
    private(set) var actionCount = 0
    func detectElements(in _: Data, snapshotId _: String?, windowContext _: WindowContext?) async throws
        -> ElementDetectionResult
    {
        ElementDetectionResult(
            snapshotId: "s",
            screenshotPath: "/tmp/s.png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: "stub",
                warnings: [],
                windowContext: nil,
                isDialog: false))
    }

    func click(target _: ClickTarget, clickType _: ClickType, snapshotId _: String?) async throws {
        self.actionCount += 1
    }

    func type(text _: String, target _: String?, clearExisting _: Bool, typingDelay _: Int, snapshotId _: String?) async
    throws {}

    func typeActions(_ actions: [TypeAction], cadence _: TypingCadence, snapshotId _: String?) async throws
        -> TypeResult
    {
        BridgeTestFixtures.typeResult(for: actions)
    }

    func scroll(_ request: ScrollRequest) async throws {
        _ = request
    }

    func hotkey(keys _: String, holdDuration _: Int) async throws {}

    func swipe(from _: CGPoint, to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile) async
    throws {}

    func hasAccessibilityPermission() async -> Bool {
        true
    }

    func waitForElement(target _: ClickTarget, timeout _: TimeInterval, snapshotId _: String?) async throws
        -> WaitForElementResult
    {
        WaitForElementResult(found: true, element: nil, waitTime: 0)
    }

    func drag(_: DragOperationRequest) async throws {}

    func moveMouse(to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile) async throws {}

    func getFocusedElement() -> UIFocusInfo? {
        nil
    }

    func findElement(matching _: UIElementSearchCriteria, in _: String?) async throws -> DetectedElement {
        throw PeekabooError.operationError(message: "stub")
    }
}

@MainActor
private func makeStubWindowService() -> ScriptedWindowInventoryService {
    let linkedTarget = AutomationTestFixtures.linkedDesktopTarget(
        processIdentity: AutomationTestFixtures.processIdentity(
            processIdentifier: 123,
            processStartIdentity: 456),
        bundleIdentifier: "dev.stub",
        applicationName: "StubApp",
        windowID: 1,
        windowTitle: "Stub",
        bounds: .init(x: 0, y: 0, width: 100, height: 100))
    let graph: LinkedApplicationInventoryGraph
    do {
        graph = try LinkedApplicationInventoryGraph(linkedTargets: [linkedTarget])
    } catch {
        preconditionFailure("Invalid bridge inventory fixture: \(error)")
    }
    return ScriptedWindowInventoryService(
        graph: graph,
        focusedWindow: linkedTarget.window)
}

@MainActor
private final class UnimplementedMenuService: MenuServiceProtocol {
    func listMenus(for _: String) async throws -> MenuStructure {
        throw PeekabooError.notImplemented("stub")
    }

    func listFrontmostMenus() async throws -> MenuStructure {
        throw PeekabooError.notImplemented("stub")
    }

    func clickMenuItem(app _: String, itemPath _: String) async throws {
        throw PeekabooError.notImplemented("stub")
    }

    func clickMenuItemByName(app _: String, itemName _: String) async throws {
        throw PeekabooError.notImplemented("stub")
    }

    func clickMenuExtra(title _: String) async throws {
        throw PeekabooError.notImplemented("stub")
    }

    func isMenuExtraMenuOpen(title _: String, ownerPID _: pid_t?) async throws -> Bool {
        false
    }

    func menuExtraOpenMenuFrame(title _: String, ownerPID _: pid_t?) async throws -> CGRect? {
        nil
    }

    func listMenuExtras() async throws -> [MenuExtraInfo] {
        []
    }

    func listMenuBarItems(includeRaw _: Bool) async throws -> [MenuBarItemInfo] {
        []
    }

    func clickMenuBarItem(named _: String) async throws -> ClickResult {
        throw PeekabooError.notImplemented("stub")
    }

    func clickMenuBarItem(at _: Int) async throws -> ClickResult {
        throw PeekabooError.notImplemented("stub")
    }
}

@MainActor
private final class UnimplementedDockService: DockServiceProtocol {
    func launchFromDock(appName _: String) async throws {}
    func findDockItem(name _: String) async throws -> DockItem {
        throw PeekabooError.notImplemented("stub")
    }

    func rightClickDockItem(appName _: String, menuItem _: String?) async throws {}
    func hideDock() async throws {}
    func showDock() async throws {}
    func listDockItems(includeAll _: Bool) async throws -> [DockItem] {
        []
    }

    func addToDock(path _: String, persistent _: Bool) async throws {}
    func removeFromDock(appName _: String) async throws {}
    func isDockAutoHidden() async -> Bool {
        false
    }
}

@MainActor
private final class UnimplementedDialogService: DialogServiceProtocol {
    func findActiveDialog(windowTitle _: String?, appName _: String?) async throws -> DialogInfo {
        throw PeekabooError.notImplemented("stub")
    }

    func clickButton(buttonText _: String, windowTitle _: String?, appName _: String?) async throws
        -> DialogActionResult
    {
        throw PeekabooError.notImplemented("stub")
    }

    func enterText(
        text _: String,
        fieldIdentifier _: String?,
        clearExisting _: Bool,
        windowTitle _: String?,
        appName _: String?) async throws -> DialogActionResult
    {
        throw PeekabooError.notImplemented("stub")
    }

    func handleFileDialog(
        path _: String?,
        filename _: String?,
        actionButton _: String?,
        ensureExpanded _: Bool,
        appName _: String?) async
        throws -> DialogActionResult
    {
        throw PeekabooError.notImplemented("stub")
    }

    func dismissDialog(force _: Bool, windowTitle _: String?, appName _: String?) async throws -> DialogActionResult {
        throw PeekabooError.notImplemented("stub")
    }

    func listDialogElements(windowTitle _: String?, appName _: String?) async throws -> DialogElements {
        throw PeekabooError.notImplemented("stub")
    }
}

@MainActor
final class StubDaemonControl: PeekabooDaemonControlProviding {
    func daemonStatus() async -> PeekabooDaemonStatus {
        PeekabooDaemonStatus(
            running: true,
            pid: getpid(),
            startedAt: Date(),
            mode: .manual,
            bridge: PeekabooDaemonBridgeStatus(
                socketPath: "/tmp/peekaboo.sock",
                hostKind: .onDemand,
                allowedOperations: [.daemonStatus]),
            activity: PeekabooDaemonActivityStatus(
                activeRequests: 0,
                lastActivityAt: Date(),
                idleTimeoutSeconds: 10,
                idleExitAt: Date().addingTimeInterval(10)))
    }

    func requestStop() async -> Bool {
        true
    }
}

private final class MutableBoolBox: @unchecked Sendable {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}

private final class PermissionLaunchRecorder: @unchecked Sendable {
    private(set) var allowAppleScriptLaunchValues: [Bool] = []

    func status(allowAppleScriptLaunch: Bool) -> PermissionsStatus {
        self.allowAppleScriptLaunchValues.append(allowAppleScriptLaunch)
        return PermissionsStatus(
            screenRecording: true,
            accessibility: true,
            appleScript: true,
            postEvent: true)
    }
}
