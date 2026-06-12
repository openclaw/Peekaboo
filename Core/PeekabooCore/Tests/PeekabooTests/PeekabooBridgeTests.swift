import CoreGraphics
import Foundation
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import Testing

struct PeekabooBridgeTests {
    private func decode(_ data: Data) throws -> PeekabooBridgeResponse {
        try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
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
        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)

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
        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)

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
    func `element actions are advertised with automation capability`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
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

        #expect(handshake.supportedOperations.contains(.setValue))
        #expect(handshake.supportedOperations.contains(.performAction))
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
                postEventAccessEvaluator: { true })
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
    func `AppleScript operations allow AppleScript probe launch during permission gate`() async throws {
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

        #expect(recorder.allowAppleScriptLaunchValues.contains(true))
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
                postEventAccessEvaluator: { postEventAccess.value })
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
        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)

        let handshake = try await client.handshake(client: identity)
        #expect(handshake.enabledOperations?.contains(.targetedHotkey) == true)

        postEventAccess.value = false
        let remote = await MainActor.run {
            RemoteUIAutomationService(client: client, supportsTargetedHotkeys: true)
        }

        do {
            try await remote.hotkey(keys: "cmd,l", holdDuration: 50, targetProcessIdentifier: 9001)
            Issue.record("Expected Event Synthesizing permission error")
        } catch PeekabooError.permissionDeniedEventSynthesizing {
            // Expected.
        }
    }

    @Test
    func `remote targeted hotkey preserves service permission errors`() async throws {
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
                postEventAccessEvaluator: { true })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)

        try await host.startChecked()
        defer { Task { await host.stop() } }

        let remote = await MainActor.run {
            RemoteUIAutomationService(
                client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
                supportsTargetedHotkeys: true)
        }

        do {
            try await remote.hotkey(keys: "cmd,l", holdDuration: 50, targetProcessIdentifier: 9001)
            Issue.record("Expected Accessibility permission error")
        } catch PeekabooError.permissionDeniedAccessibility {
            // Expected.
        }
    }

    @Test
    func `remote targeted hotkey maps invalid request envelope`() async throws {
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
                postEventAccessEvaluator: { true })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)

        try await host.startChecked()
        defer { Task { await host.stop() } }

        let remote = await MainActor.run {
            RemoteUIAutomationService(
                client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
                supportsTargetedHotkeys: true)
        }

        do {
            try await remote.hotkey(keys: "cmd,l", holdDuration: 50, targetProcessIdentifier: 9001)
            Issue.record("Expected invalid input error")
        } catch let PeekabooError.invalidInput(message) {
            #expect(message == "Target process identifier is not running: 9001")
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
                postEventAccessEvaluator: { true })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)

        try await host.startChecked()
        defer { Task { await host.stop() } }

        let remote = await MainActor.run {
            RemoteUIAutomationService(
                client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
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
    @MainActor
    func `remote services expose element actions only when handshake supports them`() {
        let client = PeekabooBridgeClient(
            socketPath: "/tmp/nonexistent-\(UUID().uuidString).sock",
            requestTimeoutSec: 1)

        let unsupported = RemotePeekabooServices(client: client, supportsElementActions: false)
        let supported = RemotePeekabooServices(client: client, supportsElementActions: true)

        #expect((unsupported.automation as? any ElementActionAutomationServiceProtocol) == nil)
        #expect((supported.automation as? any ElementActionAutomationServiceProtocol) != nil)
    }

    @Test
    func `bridge setValue forwards to automation service`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-set-value-\(UUID().uuidString).sock"
        let services = await MainActor.run { StubServices() }
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

        let remote = await MainActor.run {
            RemoteElementActionUIAutomationService(
                client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2))
        }
        let result = try await remote.setValue(target: "T1", value: .string("hello"), snapshotId: "S1")

        #expect(result.target == "T1")
        let call = await MainActor.run { services.automationStub.lastSetValue }
        #expect(call?.target == "T1")
        #expect(call?.value == .string("hello"))
        #expect(call?.snapshotId == "S1")
    }

    @Test
    func `bridge performAction forwards to automation service`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-perform-action-\(UUID().uuidString).sock"
        let services = await MainActor.run { StubServices() }
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

        let remote = await MainActor.run {
            RemoteElementActionUIAutomationService(
                client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2))
        }
        let result = try await remote.performAction(target: "B1", actionName: "AXPress", snapshotId: "S1")

        #expect(result.actionName == "AXPress")
        let call = await MainActor.run { services.automationStub.lastPerformAction }
        #expect(call?.target == "B1")
        #expect(call?.actionName == "AXPress")
        #expect(call?.snapshotId == "S1")
    }

    @Test
    func `targeted hotkey is not advertised for unsupported remote automation services`() async throws {
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
    }
}

// MARK: - Test stubs

@MainActor
final class StubServices: PeekabooBridgeServiceProviding {
    let screenCaptureStub = StubScreenCaptureService()
    let screenCapture: any ScreenCaptureServiceProtocol
    let automationStub = StubAutomationService()
    let automation: any UIAutomationServiceProtocol
    let applications: any ApplicationServiceProtocol = StubApplicationService()
    let windows: any WindowManagementServiceProtocol = StubWindowService()
    let menu: any MenuServiceProtocol = UnimplementedMenuService()
    let dock: any DockServiceProtocol = UnimplementedDockService()
    let dialogs: any DialogServiceProtocol = UnimplementedDialogService()
    let snapshots: any SnapshotManagerProtocol = SnapshotManager()
    let desktopObservationStub = StubDesktopObservationService()
    let desktopObservation: any DesktopObservationServiceProtocol
    let permissions: PermissionsService = .init()
    var lastBrowserStatusChannel: String?
    var lastBrowserExecute: PeekabooBridgeBrowserExecuteRequest?

    init() {
        self.screenCapture = self.screenCaptureStub
        self.automation = self.automationStub
        self.desktopObservation = self.desktopObservationStub
    }

    func browserStatus(channel: String?) async throws -> PeekabooBridgeBrowserStatus {
        self.lastBrowserStatusChannel = channel
        return PeekabooBridgeBrowserStatus(
            isConnected: true,
            toolCount: 1,
            detectedBrowsers: [
                PeekabooBridgeBrowserInfo(
                    name: "Google Chrome",
                    bundleIdentifier: "com.google.Chrome",
                    processIdentifier: 42,
                    version: "144.0",
                    channel: "stable"),
            ])
    }

    func browserExecute(_ request: PeekabooBridgeBrowserExecuteRequest) async throws
    -> PeekabooBridgeBrowserToolResponse {
        self.lastBrowserExecute = request
        return PeekabooBridgeBrowserToolResponse(
            content: [
                .object([
                    "type": .string("text"),
                    "text": .string("ok"),
                ]),
            ],
            isError: false,
            meta: nil)
    }
}

@MainActor
private final class StubNonTargetedServices: PeekabooBridgeServiceProviding {
    let screenCapture: any ScreenCaptureServiceProtocol = StubScreenCaptureService()
    let automation: any UIAutomationServiceProtocol = StubNonTargetedAutomationService()
    let applications: any ApplicationServiceProtocol = StubApplicationService()
    let windows: any WindowManagementServiceProtocol = StubWindowService()
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
    let windows: any WindowManagementServiceProtocol = StubWindowService()
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
        return DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: StubScreenCaptureService.sampleData,
                savedPath: "/tmp/stub.png",
                metadata: CaptureMetadata(
                    size: .init(width: 1, height: 1),
                    mode: .screen,
                    timestamp: Date())),
            elements: nil,
            files: DesktopObservationFiles(rawScreenshotPath: "/tmp/stub.png"))
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
final class StubAutomationService: TargetedHotkeyServiceProtocol, TargetedClickServiceProtocol,
ElementActionAutomationServiceProtocol {
    struct Click { let target: ClickTarget; let type: ClickType }
    struct TargetedHotkey {
        let keys: String
        let holdDuration: Int
        let targetProcessIdentifier: pid_t?
    }

    struct TargetedClick { let target: ClickTarget; let type: ClickType; let targetProcessIdentifier: pid_t? }

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

    private(set) var lastClick: Click?
    private(set) var lastProcessTargetedHotkey: TargetedHotkey?
    private(set) var lastProcessTargetedClick: TargetedClick?
    private(set) var lastSetValue: SetValue?
    private(set) var lastPerformAction: PerformAction?
    var targetedHotkeyError: (any Error)?

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
        self.lastClick = Click(target: target, type: clickType)
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId _: String?,
        targetProcessIdentifier: pid_t) async throws
    {
        self.lastProcessTargetedClick = TargetedClick(
            target: target,
            type: clickType,
            targetProcessIdentifier: targetProcessIdentifier)
    }

    func type(text _: String, target _: String?, clearExisting _: Bool, typingDelay _: Int, snapshotId _: String?) async
    throws {}

    func typeActions(_ actions: [TypeAction], cadence _: TypingCadence, snapshotId _: String?) async throws
        -> TypeResult
    {
        TypeResult(totalCharacters: actions.count, keyPresses: actions.count)
    }

    func setValue(target: String, value: UIElementValue, snapshotId: String?) async throws -> ElementActionResult {
        self.lastSetValue = SetValue(target: target, value: value, snapshotId: snapshotId)
        return ElementActionResult(
            target: target,
            actionName: "AXSetValue",
            anchorPoint: nil,
            newValue: value.displayString)
    }

    func performAction(target: String, actionName: String, snapshotId: String?) async throws -> ElementActionResult {
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
            targetProcessIdentifier: targetProcessIdentifier)
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
private final class StubNonTargetedAutomationService: UIAutomationServiceProtocol {
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

    func click(target _: ClickTarget, clickType _: ClickType, snapshotId _: String?) async throws {}

    func type(text _: String, target _: String?, clearExisting _: Bool, typingDelay _: Int, snapshotId _: String?) async
    throws {}

    func typeActions(_ actions: [TypeAction], cadence _: TypingCadence, snapshotId _: String?) async throws
        -> TypeResult
    {
        TypeResult(totalCharacters: actions.count, keyPresses: actions.count)
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
private final class StubWindowService: WindowManagementServiceProtocol {
    private let windowsList: [ServiceWindowInfo] = [
        ServiceWindowInfo(windowID: 1, title: "Stub", bounds: .init(x: 0, y: 0, width: 100, height: 100)),
    ]

    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target _: WindowTarget) async throws {}
    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        self.windowsList
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        self.windowsList.first
    }
}

@MainActor
private final class StubApplicationService: ApplicationServiceProtocol {
    private let app = ServiceApplicationInfo(
        processIdentifier: 123,
        bundleIdentifier: "dev.stub",
        name: "StubApp",
        bundlePath: nil,
        isActive: true,
        isHidden: false,
        windowCount: 1)

    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        UnifiedToolOutput(
            data: ServiceApplicationListData(applications: [self.app]),
            summary: .init(brief: "1 app", status: .success, counts: ["applications": 1]),
            metadata: .init(duration: 0))
    }

    func findApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        self.app
    }

    func listWindows(for _: String, timeout _: Float?) async throws -> UnifiedToolOutput<ServiceWindowListData> {
        UnifiedToolOutput(
            data: ServiceWindowListData(windows: [], targetApplication: self.app),
            summary: .init(brief: "0 windows", status: .success, counts: [:]),
            metadata: .init(duration: 0))
    }

    func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        self.app
    }

    func isApplicationRunning(identifier _: String) async -> Bool {
        true
    }

    func launchApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        self.app
    }

    func activateApplication(identifier _: String) async throws {}
    func quitApplication(identifier _: String, force _: Bool) async throws -> Bool {
        true
    }

    func hideApplication(identifier _: String) async throws {}
    func unhideApplication(identifier _: String) async throws {}
    func hideOtherApplications(identifier _: String) async throws {}
    func showAllApplications() async throws {}
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
private final class StubDaemonControl: PeekabooDaemonControlProviding {
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
