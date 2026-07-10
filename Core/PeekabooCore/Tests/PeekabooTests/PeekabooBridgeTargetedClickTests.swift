import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import Testing

struct PeekabooBridgeTargetedClickTests {
    private func decode(_ data: Data) throws -> PeekabooBridgeResponse {
        try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
    }

    @Test
    func `targeted click operation reflects exact window requirement`() {
        let processRequest = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001))
        let windowRequest = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001,
            targetWindowID: 42))

        #expect(processRequest.operation == .targetedClick)
        #expect(windowRequest.operation == .exactWindowTargetedClick)
    }

    @Test
    @MainActor
    func `exact window click requires exact window allowlist operation`() async throws {
        let request = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001,
            targetWindowID: 42))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let permissions = PermissionsStatus(
            screenRecording: false,
            accessibility: true,
            appleScript: false,
            postEvent: false)

        let targetedOnly = PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.targetedClick],
            permissionStatusEvaluator: { _ in permissions })
        let rejected = try await self.decode(targetedOnly.decodeAndHandle(requestData, peer: nil))
        guard case let .error(envelope) = rejected else {
            Issue.record("Expected exact-window request to be rejected, got \(rejected)")
            return
        }
        #expect(envelope.code == .operationNotSupported)

        let exactOnly = PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.exactWindowTargetedClick],
            permissionStatusEvaluator: { _ in permissions })
        let accepted = try await self.decode(exactOnly.decodeAndHandle(requestData, peer: nil))
        guard case .ok = accepted else {
            Issue.record("Expected exact-window request to succeed, got \(accepted)")
            return
        }
    }

    @Test
    @MainActor
    func `automation targeted click is forwarded`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })

        let request = PeekabooBridgeRequest.targetedClick(
            PeekabooBridgeTargetedClickRequest(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: 9001))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case .ok = response else {
            Issue.record("Expected ok response, got \(response)")
            return
        }

        let lastClick = services.automationStub.lastProcessTargetedClick
        if case let .coordinates(point) = lastClick?.target {
            #expect(point == CGPoint(x: 10, y: 20))
        } else {
            Issue.record("Expected coordinates click, got \(String(describing: lastClick?.target))")
        }
        #expect(lastClick?.type == .single)
        #expect(lastClick?.targetProcessIdentifier == 9001)
        #expect(lastClick?.targetWindowID == nil)
    }

    @Test
    @MainActor
    func `automation targeted click preserves exact window`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let request = PeekabooBridgeRequest.targetedClick(.init(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .single,
            snapshotId: nil,
            targetProcessIdentifier: 9001,
            targetWindowID: 42))

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil)
        let response = try self.decode(responseData)

        guard case .ok = response else {
            Issue.record("Expected ok response, got \(response)")
            return
        }
        #expect(services.automationStub.lastProcessTargetedClick?.targetWindowID == 42)
    }

    @Test
    @MainActor
    func `remote targeted click preserves actionable snapshot failures`() async throws {
        let cases: [(PeekabooError, PeekabooBridgeErrorCode, PeekabooBridgeErrorKind, String)] = [
            (.snapshotStale("window moved"), .invalidRequest, .snapshotStale, "window moved"),
            (.snapshotNotFound("expired"), .notFound, .snapshotNotFound, "expired"),
        ]
        for (error, expectedCode, expectedKind, expectedContext) in cases {
            let services = StubServices()
            services.automationStub.targetedClickError = error
            let server = PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true },
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: true,
                        appleScript: false,
                        postEvent: true)
                })
            let request = PeekabooBridgeRequest.targetedClick(.init(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: 9001,
                targetWindowID: 42))

            let responseData = try await server.decodeAndHandle(
                JSONEncoder.peekabooBridgeEncoder().encode(request),
                peer: nil)
            guard case let .error(envelope) = try self.decode(responseData) else {
                Issue.record("Expected bridge error for \(error)")
                continue
            }
            #expect(envelope.code == expectedCode)
            #expect(envelope.message == error.localizedDescription)
            #expect(envelope.kind == expectedKind)
            #expect(envelope.context == expectedContext)
        }
    }

    @Test
    @MainActor
    func `remote targeted click restores snapshot errors from bridge envelopes`() async throws {
        let cases: [(PeekabooError, PeekabooBridgeErrorKind)] = [
            (.snapshotStale("window moved"), .snapshotStale),
            (.snapshotNotFound("expired"), .snapshotNotFound),
        ]
        for (sourceError, expectedKind) in cases {
            let socketPath = "/tmp/peekaboo-bridge-snapshot-error-\(UUID().uuidString).sock"
            let services = StubServices()
            services.automationStub.targetedClickError = sourceError
            let server = PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: true,
                        appleScript: false,
                        postEvent: false)
                })
            let host = PeekabooBridgeHost(
                socketPath: socketPath,
                server: server,
                allowedTeamIDs: [],
                requestTimeoutSec: 2)
            try await host.startChecked()
            defer { Task { await host.stop() } }
            let remote = RemoteUIAutomationService(
                client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
                supportsTargetedClicks: true)

            do {
                try await remote.click(
                    target: .elementId("B1"),
                    clickType: .single,
                    snapshotId: "snapshot",
                    targetProcessIdentifier: getpid())
                Issue.record("Expected snapshot error")
            } catch let error as PeekabooError {
                switch (expectedKind, error) {
                case let (.snapshotStale, .snapshotStale(reason)):
                    #expect(reason == "window moved")
                case let (.snapshotNotFound, .snapshotNotFound(snapshotId)):
                    #expect(snapshotId == "expired")
                default:
                    Issue.record("Unexpected snapshot error: \(error)")
                }
            } catch {
                Issue.record("Unexpected bridge error: \(error)")
            }
        }
    }

    @Test
    @MainActor
    func `real click service preserves stale snapshot through bridge facade`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-real-stale-\(UUID().uuidString).sock"
        let services = PeekabooServices(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly))
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let remote = RemoteUIAutomationService(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
            supportsTargetedClicks: true,
            supportsExactWindowTargetedClicks: true)

        do {
            try await remote.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "expired-snapshot",
                targetProcessIdentifier: getpid(),
                targetWindowID: 42)
            Issue.record("Expected stale snapshot error")
        } catch let PeekabooError.snapshotStale(reason) {
            #expect(reason.contains("no longer available"))
        } catch {
            Issue.record("Unexpected bridge error: \(error)")
        }
    }

    @Test
    @MainActor
    func `targeted click is disabled when both delivery permissions are missing`() async throws {
        let server = PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: false,
                    appleScript: false,
                    postEvent: false)
            })

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

        #expect(handshake.supportedOperations.contains(.targetedClick))
        #expect(handshake.enabledOperations?.contains(.targetedClick) == false)
        #expect(handshake.supportedOperations.contains(.exactWindowTargetedClick))
        #expect(handshake.enabledOperations?.contains(.exactWindowTargetedClick) == false)
        #expect(handshake.permissionTags[PeekabooBridgeOperation.targetedClick.rawValue] == [])
        #expect(handshake.supportedOperations.contains(.quitApplication))
        #expect(handshake.enabledOperations?.contains(.quitApplication) == true)
        #expect(handshake.permissionTags[PeekabooBridgeOperation.quitApplication.rawValue] == [])
        #expect(handshake.enabledOperations?.contains(.hideApplication) == false)
    }

    @Test
    @MainActor
    func `targeted click requires accessibility now that delivery is AX-only`() async throws {
        // Positioned pid-routed mouse events mis-deliver at the window corner, so the synthetic
        // path was removed; Event Synthesizing permission alone no longer enables targeted clicks.
        for (accessibility, postEvent, expectedEnabled) in [
            (true, false, true),
            (true, true, true),
            (false, true, false),
        ] {
            let server = PeekabooBridgeServer(
                services: StubServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { postEvent },
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: accessibility,
                        appleScript: false,
                        postEvent: postEvent)
                })
            let identity = PeekabooBridgeClientIdentity(
                bundleIdentifier: "dev.peeka.cli",
                teamIdentifier: "TEAMID",
                processIdentifier: getpid(),
                hostname: Host.current().name)
            let request = PeekabooBridgeRequest.handshake(.init(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                client: identity,
                requestedHostKind: .gui))

            let responseData = try await server.decodeAndHandle(
                JSONEncoder.peekabooBridgeEncoder().encode(request),
                peer: nil)
            let response = try self.decode(responseData)
            guard case let .handshake(handshake) = response else {
                Issue.record("Expected handshake response, got \(response)")
                continue
            }

            #expect(handshake.enabledOperations?.contains(.targetedClick) == expectedEnabled)
            #expect(handshake.enabledOperations?.contains(.exactWindowTargetedClick) == expectedEnabled)
        }
    }

    @Test
    @MainActor
    func `protocol 1_8 targeted click retains its post event permission contract`() async throws {
        let server = PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)
        let request = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: .init(major: 1, minor: 8),
            client: identity,
            requestedHostKind: .gui))

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil)
        guard case let .handshake(handshake) = try self.decode(responseData) else {
            Issue.record("Expected handshake response")
            return
        }

        #expect(handshake.supportedOperations.contains(.targetedClick))
        #expect(handshake.enabledOperations?.contains(.targetedClick) == false)
        #expect(handshake.permissionTags[PeekabooBridgeOperation.targetedClick.rawValue] == [.postEvent])
    }

    @Test
    @MainActor
    func `accessibility-only host accepts single element targeted click`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let request = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001))

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil)
        let response = try self.decode(responseData)

        guard case .ok = response else {
            Issue.record("Expected ok response, got \(response)")
            return
        }
        #expect(services.automationStub.lastProcessTargetedClick?.type == .single)
    }

    @Test
    @MainActor
    func `accessibility-only host accepts coordinate targeted clicks`() async throws {
        // Coordinate background clicks are now hit-tested and pressed via accessibility, so
        // they no longer require Event Synthesizing permission.
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let payload = PeekabooBridgeTargetedClickRequest(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .single,
            snapshotId: nil,
            targetProcessIdentifier: 9001)

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(PeekabooBridgeRequest.targetedClick(payload)),
            peer: nil)
        let response = try self.decode(responseData)

        guard case .ok = response else {
            Issue.record("Expected ok response, got \(response)")
            return
        }
        #expect(services.automationStub.lastProcessTargetedClick?.type == .single)
    }

    @Test
    @MainActor
    func `post event only host rejects targeted clicks with accessibility permission`() async throws {
        let requests: [PeekabooBridgeTargetedClickRequest] = [
            .init(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: 9001),
            .init(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: 9001),
        ]

        for payload in requests {
            let services = StubServices()
            let server = PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true },
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: false,
                        appleScript: false,
                        postEvent: true)
                })
            let responseData = try await server.decodeAndHandle(
                JSONEncoder.peekabooBridgeEncoder().encode(PeekabooBridgeRequest.targetedClick(payload)),
                peer: nil)
            let response = try self.decode(responseData)

            guard case let .error(envelope) = response else {
                Issue.record("Expected permission error, got \(response)")
                continue
            }
            #expect(envelope.code == .permissionDenied)
            #expect(envelope.permission == .accessibility)
            #expect(services.automationStub.lastProcessTargetedClick == nil)
        }
    }

    @Test
    @MainActor
    func `remote accessibility-only host allows element right click`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-right-click-\(UUID().uuidString).sock"
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let remote = RemoteUIAutomationService(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
            supportsTargetedClicks: true,
            targetedClickRequiresEventSynthesizingPermission: true)

        try await remote.click(
            target: .elementId("B1"),
            clickType: .right,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001)

        #expect(services.automationStub.lastProcessTargetedClick?.type == .right)
    }

    @Test
    @MainActor
    func `remote element right click maps synthetic fallback permission denial`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-right-click-\(UUID().uuidString).sock"
        let services = StubServices()
        services.automationStub.targetedClickError = PeekabooError.permissionDeniedEventSynthesizing
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let remote = RemoteUIAutomationService(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
            supportsTargetedClicks: true,
            targetedClickRequiresEventSynthesizingPermission: true)

        do {
            try await remote.click(
                target: .query("Save"),
                clickType: .right,
                snapshotId: "snapshot",
                targetProcessIdentifier: 9001)
            Issue.record("Expected Event Synthesizing permission error")
        } catch PeekabooError.permissionDeniedEventSynthesizing {
            // Expected after the AX path falls back to synthetic input.
        }
    }

    @Test
    @MainActor
    func `remote coordinate click is not preflight-rejected on an accessibility-only host`() async {
        // Current hosts deliver coordinate targeted clicks through accessibility, so the client
        // must not reject them for missing Event Synthesizing even when the legacy availability
        // flag is set. The request must reach transport (and here fail against a missing socket)
        // rather than throw `permissionDeniedEventSynthesizing` up front.
        let remote = RemoteUIAutomationService(
            client: PeekabooBridgeClient(
                socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
                requestTimeoutSec: 0.1),
            supportsTargetedClicks: true,
            targetedClickRequiresEventSynthesizingPermission: true)

        do {
            try await remote.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: 9001)
            Issue.record("Expected a transport error against the missing socket")
        } catch PeekabooError.permissionDeniedEventSynthesizing {
            Issue.record("Coordinate click must not be preflight-rejected for Event Synthesizing")
        } catch {
            // Expected: the request reached transport and failed to connect to the missing socket.
        }
    }

    @Test
    @MainActor
    func `remote exact window click rejects an older bridge before transport`() async {
        let remote = RemoteUIAutomationService(
            client: PeekabooBridgeClient(
                socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
                requestTimeoutSec: 0.1),
            supportsTargetedClicks: true,
            supportsExactWindowTargetedClicks: false)

        do {
            try await remote.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: 9001,
                targetWindowID: 42)
            Issue.record("Expected exact-window capability error")
        } catch PeekabooError.serviceUnavailable {
            // Expected before the missing socket is contacted.
        } catch {
            Issue.record("Unexpected transport or capability error: \(error)")
        }
    }

    @Test
    func `targeted click defers permission checks to its selected input path`() {
        #expect(PeekabooBridgeOperation.targetedHotkey.requiredPermissions == [.postEvent])
        #expect(PeekabooBridgeOperation.targetedClick.requiredPermissions.isEmpty)
        #expect(!PeekabooBridgeTargetedClickRequest.requiresPostEventPermission(
            target: .elementId("B1"),
            clickType: .right))
        #expect(!PeekabooBridgeTargetedClickRequest.requiresPostEventPermission(
            target: .query("Save"),
            clickType: .right))
        #expect(PeekabooBridgeTargetedClickRequest.requiresPostEventPermission(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .right))
        #expect(PeekabooBridgeTargetedClickRequest.requiresPostEventPermission(
            target: .elementId("B1"),
            clickType: .double))
    }

    @Test
    func `element action operations require accessibility permission`() {
        #expect(PeekabooBridgeOperation.setValue.requiredPermissions == [.accessibility])
        #expect(PeekabooBridgeOperation.performAction.requiredPermissions == [.accessibility])
    }

    @Test
    func `desktop observation operation requires screen recording permission`() {
        #expect(PeekabooBridgeOperation.desktopObservation.requiredPermissions == [.screenRecording])
    }

    @Test
    func `application quit does not require AppleScript permission`() {
        #expect(PeekabooBridgeOperation.quitApplication.requiredPermissions.isEmpty)
        #expect(PeekabooBridgeOperation.hideApplication.requiredPermissions == [.appleScript])
    }
}
