import Foundation
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import Testing

struct RemoteApplicationServiceTests {
    @Test
    func `remote application list preserves bounded partial metadata across Bridge`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-partial-apps-\(UUID().uuidString).sock"
        let applications = await MainActor.run { PartialInventoryApplicationService() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applications),
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
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let remote = await MainActor.run {
            RemoteApplicationService(client: client)
        }

        let output = try await remote.listApplications()
        let app = try #require(output.data.applications.first)

        #expect(app.isHiddenKnown == false)
        #expect(app.metadataWarnings == PartialInventoryApplicationService.warnings)
        #expect(output.summary.status == .partial)
        #expect(output.summary.counts["incompleteApplications"] == 1)
        #expect(output.metadata.warnings == PartialInventoryApplicationService.warnings)
        await host.stop()
    }

    @Test
    func `remote running check propagates transport failure instead of returning false`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-transport-failure-\(UUID().uuidString).sock"
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(
            client: Self.clientIdentity,
            protocolVersion: PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion)
        await host.stop()
        let remote = await MainActor.run {
            RemoteApplicationService(client: client)
        }

        await #expect(throws: (any Error).self) {
            _ = try await remote.isApplicationRunning(identifier: "TextEdit")
        }
    }

    @Test
    func `legacy bridge quit payload decodes without process identity`() throws {
        let data = Data(#"{"identifier":"PID:123","force":false}"#.utf8)

        let request = try JSONDecoder().decode(PeekabooBridgeQuitAppRequest.self, from: data)

        #expect(request.identifier == "PID:123")
        #expect(!request.force)
        #expect(request.expectedIdentity == nil)
    }

    @Test
    func `old bridge rejects pinned quit before transport`() async throws {
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(
                    socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
                    requestTimeoutSec: 0.1),
                supportsPinnedQuit: false)
        }
        let request = ApplicationQuitRequest(
            identifier: "PID:123",
            expectedIdentity: ApplicationProcessIdentity(
                processIdentifier: 123,
                processStartIdentity: 456))

        do {
            _ = try await remote.quitApplication(request: request)
            Issue.record("Expected pinned-quit capability rejection")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .operationNotSupported)
            #expect(envelope.message.contains("process-generation-pinned"))
        }
    }

    @Test
    func `old bridge rejects pinned activation before transport`() async throws {
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(
                    socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
                    requestTimeoutSec: 0.1),
                supportsPinnedActivation: false)
        }

        do {
            try await remote.activateApplication(request: ApplicationActivationRequest(
                identifier: "PID:123",
                expectedIdentity: ApplicationProcessIdentity(
                    processIdentifier: 123,
                    processStartIdentity: 456)))
            Issue.record("Expected pinned-activation capability rejection")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .operationNotSupported)
            #expect(envelope.message.contains("process-generation-pinned activation"))
        }
    }

    @Test
    func `old bridge rejects pinned hide before transport`() async throws {
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(
                    socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
                    requestTimeoutSec: 0.1),
                supportsPinnedHide: false)
        }
        let request = try ApplicationHideRequest(
            identifier: "PID:123",
            expectedIdentity: .init(processIdentifier: 123, processStartIdentity: 456))

        do {
            _ = try await remote.hideApplicationTargetedResult(request: request)
            Issue.record("Expected pinned-hide capability rejection")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .operationNotSupported)
            #expect(envelope.message.contains("process-generation-pinned application hide"))
        }
    }

    @Test
    func `protocol 1 29 void activation request auto pins the live process`() async throws {
        let socketPath = "/tmp/peekaboo-remote-app-activation-pin-\(UUID().uuidString).sock"
        let applications = await MainActor.run {
            let applications = StubApplicationService()
            applications.actionOutcome = .confirmedChange(
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                unitCount: .one)
            return applications
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applications),
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

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.activation-pin-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        try await client.activateApplication(request: .init(identifier: "StubApp"))

        let requests = await MainActor.run { applications.activationRequests }
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.identifier == "PID:123")
        #expect(request.expectedIdentity == .init(
            processIdentifier: 123,
            processStartIdentity: 456))
        await host.stop()
    }

    @Test
    func `protocol 1 29 hides activation without application lookup`() async throws {
        let socketPath = "/tmp/peekaboo-remote-app-activation-dependency-\(UUID().uuidString).sock"
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: StubApplicationService()),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: [.activateApplication])
        }
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let handshake = try await TrustedBridgeClientFixture.make(socketPath: socketPath).handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.activation-dependency-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        #expect(!handshake.supportedOperations.contains(.activateApplication))
        #expect(handshake.enabledOperations?.contains(.activateApplication) == false)
        await host.stop()
    }

    @Test
    func `protocol 1 28 activation and hide preserve outcomes without receipt authority`() async throws {
        let root = URL(fileURLWithPath: "/tmp/peekaboo-legacy-activation-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = await MainActor.run { StubApplicationService() }
        await MainActor.run {
            applications.actionOutcome = .confirmedChange(
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                unitCount: .one)
        }
        let legacyVersion = PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applications),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: legacyVersion...legacyVersion,
                allowedOperations: [.activateApplication, .findApplication, .hideApplication])
        }
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = PeekabooBridgeClient(socketPath: socketPath)
        let handshake = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.legacy-activation-tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: legacyVersion)
        #expect(handshake.supportedOperations.contains(.activateApplication))
        #expect(handshake.operationAttestation == nil)
        let activationResult = try await client.activateApplicationTargetedResult(request: .init(
            identifier: "StubApp"))
        #expect(activationResult.outcome == DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one).routed(to: .bridge))
        #expect(activationResult.targetIdentity == nil)
        let request = try #require(await MainActor.run { applications.activationRequests.first })
        #expect(request.identifier == "StubApp")
        #expect(request.expectedIdentity == nil)

        await MainActor.run {
            applications.actionOutcome = .dispatchedUnverified(
                delivery: .init(mechanism: .nativeFramework, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one)
        }
        let hideResult = try await client.hideApplicationTargetedResult(identifier: "StubApp")
        #expect(hideResult.outcome == DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one).routed(to: .bridge))
        #expect(hideResult.targetIdentity == nil)
        let artifacts = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!artifacts.contains { $0.contains(".receipts") })
        await host.stop()
    }

    @Test
    func `old bridge rejects background launch before transport`() async throws {
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(
                    socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
                    requestTimeoutSec: 0.1),
                supportsLaunchOptions: true,
                supportsSafeBackgroundLaunchNoOp: false)
        }

        do {
            _ = try await remote.launchApplication(request: ApplicationLaunchRequest(
                applicationIdentifier: "Finder"))
            Issue.record("Expected background launch semantic capability rejection")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .operationNotSupported)
            #expect(envelope.message.contains("safe background launch semantics"))
        }
    }

    @Test
    func `old bridge rejects legacy remote quit before transport`() async throws {
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(
                    socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
                    requestTimeoutSec: 0.1),
                supportsPinnedQuit: false)
        }

        do {
            _ = try await remote.quitApplication(identifier: "TextEdit", force: false)
            Issue.record("Expected legacy quit capability rejection")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .operationNotSupported)
            #expect(envelope.message.contains("process-generation-pinned"))
        }
    }

    @Test
    func `current remote rejects missing quit receipt before transport`() async throws {
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(
                    socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
                    requestTimeoutSec: 0.1),
                supportsPinnedQuit: true)
        }

        do {
            _ = try await remote.quitApplication(request: ApplicationQuitRequest(
                identifier: "PID:123",
                force: false))
            Issue.record("Expected missing quit receipt rejection")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .operationNotSupported)
            #expect(envelope.message.contains("process-generation identity"))
            #expect(envelope.message.contains("resolve the app again"))
        }
    }

    @Test
    func `current bridge forwards pinned quit identity`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-pinned-quit-\(UUID().uuidString).sock"
        let applications = await MainActor.run { StubApplicationService() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applications),
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

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: client,
                supportsPinnedQuit: true)
        }
        let request = ApplicationQuitRequest(
            identifier: "PID:123",
            force: true,
            expectedIdentity: ApplicationProcessIdentity(
                processIdentifier: 123,
                processStartIdentity: 456))

        #expect(try await remote.quitApplication(request: request))
        #expect(await MainActor.run { applications.quitRequests } == [request])
        await host.stop()
    }

    @Test
    func `current remote preserves the canonical application outcome`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-app-outcome-\(UUID().uuidString).sock"
        let applications = await MainActor.run { StubApplicationService() }
        let expected = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one)
        await MainActor.run { applications.actionOutcome = expected }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applications),
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

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil))
        let remote = await MainActor.run {
            RemoteApplicationService(client: client, supportsPinnedQuit: true)
        }
        let result = try await remote.quitApplicationResult(request: ApplicationQuitRequest(
            identifier: "PID:123",
            force: true,
            expectedIdentity: .init(processIdentifier: 123, processStartIdentity: 456)))

        #expect(result.payload)
        #expect(result.outcome == expected.routed(to: .bridge))
        await host.stop()
    }

    @Test
    func `quit rejection remains false for legacy clients and canonical for current clients`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-quit-refusal-\(UUID().uuidString).sock"
        let applications = await MainActor.run { StubApplicationService() }
        let refusal = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "The native quit request was rejected.",
            hint: "Refresh the application inventory before retrying.")
        await MainActor.run { applications.quitResultError = refusal }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applications),
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
        let request = ApplicationQuitRequest(
            identifier: "PID:123",
            force: false,
            expectedIdentity: .init(processIdentifier: 123, processStartIdentity: 456))
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(
            client: Self.clientIdentity,
            protocolVersion: PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion)

        let legacySucceeded = try await client.quitApplication(
            request: request,
            supportsPinnedQuit: true)
        #expect(!legacySucceeded)

        _ = try await client.handshake(client: PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil))
        let remote = await MainActor.run {
            RemoteApplicationService(client: client, supportsPinnedQuit: true)
        }
        for operation in [
            { _ = try await remote.quitApplication(request: request) },
            { _ = try await remote.quitApplication(identifier: "StubApp", force: false) },
            { _ = try await remote.quitApplicationResult(request: request) },
        ] {
            do {
                try await operation()
                Issue.record("Expected current quit refusal")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome == refusal.outcome.routed(to: .bridge))
                #expect(failure.outcome.refusalReason == .targetUnavailable)
                #expect(failure.outcome.dispatchState == .none)
            }
        }
        await host.stop()
    }

    @Test
    func `current bridge legacy quit resolves and forwards pinned identity`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-legacy-quit-\(UUID().uuidString).sock"
        let applications = await MainActor.run { StubApplicationService() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applications),
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
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: client,
                supportsPinnedQuit: true)
        }

        #expect(try await remote.quitApplication(identifier: "StubApp", force: true))

        let request = try #require(await MainActor.run { applications.quitRequests.first })
        #expect(request.identifier == "PID:123")
        #expect(request.force)
        #expect(request.expectedIdentity == ApplicationProcessIdentity(
            processIdentifier: 123,
            processStartIdentity: 456))
        await host.stop()
    }

    @Test
    func `remote legacy quit rejects PID reuse without terminating replacement`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-reused-quit-\(UUID().uuidString).sock"
        let applications = await MainActor.run { ReusedPIDQuitApplicationService() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applications),
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
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: client,
                supportsPinnedQuit: true)
        }

        await #expect(throws: (any Error).self) {
            try await remote.quitApplication(identifier: "TextEdit", force: true)
        }

        #expect(await MainActor.run { applications.terminationCount } == 0)
        #expect(await MainActor.run { applications.receivedQuitRequests.count } == 1)
        await host.stop()
    }

    @Test
    func `legacy bridge rejects background launch options before transport`() async throws {
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(
                    socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
                    requestTimeoutSec: 0.1),
                supportsLaunchOptions: false)
        }

        do {
            _ = try await remote.launchApplication(request: ApplicationLaunchRequest(
                applicationIdentifier: "Calculator",
                activates: false))
            Issue.record("Expected legacy bridge launch option rejection")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .operationNotSupported)
            #expect(envelope.message.contains("update or relaunch"))
        }
    }

    @Test
    func `old bridge rejects protocol 1_13 launch options before transport`() async throws {
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(
                    socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
                    requestTimeoutSec: 0.1),
                supportsLaunchOptions: true,
                supportsNewInstanceLaunch: false)
        }

        let cases = [
            (
                ApplicationLaunchRequest(applicationIdentifier: "TextEdit", createsNewInstance: true),
                "new-instance"),
            (
                ApplicationLaunchRequest(applicationIdentifier: "TextEdit", waitForWindow: true),
                "window-ready"),
        ]
        for (request, expectedMessage) in cases {
            do {
                _ = try await remote.launchApplication(request: request)
                Issue.record("Expected \(expectedMessage) capability rejection")
            } catch let envelope as PeekabooBridgeErrorEnvelope {
                #expect(envelope.code == .operationNotSupported)
                #expect(envelope.message.contains(expectedMessage))
            }
        }
    }

    @Test
    func `legacy bridge rejects atomic relaunch before transport`() async throws {
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(
                    socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
                    requestTimeoutSec: 0.1),
                supportsRelaunch: false)
        }
        let request = ApplicationRelaunchRequest(
            targetIdentifier: "PID:123",
            expectedTargetIdentity: ApplicationProcessIdentity(
                processIdentifier: 123,
                processStartIdentity: 456),
            launchRequest: ApplicationLaunchRequest(applicationIdentifier: "Calculator"),
            waitSeconds: 0)

        do {
            _ = try await remote.relaunchApplication(request: request)
            Issue.record("Expected legacy bridge relaunch rejection")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .operationNotSupported)
            #expect(envelope.message.contains("update or relaunch"))
        }
    }

    @Test
    func `old bridge rejects protocol 1_13 relaunch options before transport`() async throws {
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(
                    socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
                    requestTimeoutSec: 0.1),
                supportsLaunchOptions: true,
                supportsNewInstanceLaunch: false,
                supportsWindowReadiness: false,
                supportsRelaunch: true)
        }
        let cases = [
            (
                ApplicationLaunchRequest(applicationIdentifier: "TextEdit", createsNewInstance: true),
                "new-instance"),
            (
                ApplicationLaunchRequest(applicationIdentifier: "TextEdit", waitForWindow: true),
                "window-ready"),
        ]

        for (launchRequest, expectedMessage) in cases {
            do {
                _ = try await remote.relaunchApplication(request: ApplicationRelaunchRequest(
                    targetIdentifier: "PID:123",
                    expectedTargetIdentity: ApplicationProcessIdentity(
                        processIdentifier: 123,
                        processStartIdentity: 456),
                    launchRequest: launchRequest,
                    waitSeconds: 0))
                Issue.record("Expected \(expectedMessage) relaunch capability rejection")
            } catch let envelope as PeekabooBridgeErrorEnvelope {
                #expect(envelope.code == .operationNotSupported)
                #expect(envelope.message.contains(expectedMessage))
            }
        }
    }

    @Test
    func `current bridge forwards protocol 1_13 relaunch options`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-relaunch-\(UUID().uuidString).sock"
        let applications = await MainActor.run {
            let service = StubApplicationService()
            service.relaunchResult = ServiceApplicationInfo(
                processIdentifier: 124,
                processStartIdentity: 789,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit",
                bundlePath: nil,
                isActive: true,
                isHidden: false,
                windowCount: 1)
                .withUniqueTestSelectorProof(for: "TextEdit")
            return service
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applications),
                hostKind: .onDemand,
                allowlistedTeams: [],
                allowlistedBundles: [],
                daemonControl: StubDaemonControl())
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: client,
                supportsLaunchOptions: true,
                supportsNewInstanceLaunch: true,
                supportsWindowReadiness: true,
                supportsRelaunch: true)
        }
        let request = ApplicationRelaunchRequest(
            targetIdentifier: "PID:123",
            expectedTargetIdentity: ApplicationProcessIdentity(
                processIdentifier: 123,
                processStartIdentity: 456),
            launchRequest: ApplicationLaunchRequest(
                applicationIdentifier: "TextEdit",
                waitForWindow: true,
                createsNewInstance: true),
            waitSeconds: 0)

        let relaunched = try await remote.relaunchApplication(request: request)

        #expect(await MainActor.run { applications.relaunchRequests } == [request])
        #expect(relaunched.processIdentity == ApplicationProcessIdentity(
            processIdentifier: 124,
            processStartIdentity: 789))
        await host.stop()
    }

    @Test
    func `native lifecycle uses bridge without AppleScript permission`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-app-fallback-\(UUID().uuidString).sock"
        let bridgedApplications = await MainActor.run { RecordingApplicationFallback() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: bridgedApplications),
                hostKind: .onDemand,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: true,
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

        let directClient = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await directClient.handshake(client: Self.clientIdentity)
        try await directClient.hideApplication(identifier: "Finder")

        let fallback = await MainActor.run { RecordingApplicationFallback() }
        let remoteClient = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await remoteClient.handshake(client: Self.clientIdentity)
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: remoteClient,
                localFallback: fallback)
        }

        try await remote.hideApplication(identifier: "Finder")
        let bridgedIdentifiers = await MainActor.run { bridgedApplications.hiddenIdentifiers }
        let hiddenIdentifiers = await MainActor.run { fallback.hiddenIdentifiers }
        #expect(bridgedIdentifiers == ["PID:123", "PID:123"])
        #expect(hiddenIdentifiers.isEmpty)
    }

    @Test
    func `indeterminate lifecycle failure never replays through local fallback`() async throws {
        let testID = String(UUID().uuidString.prefix(8))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-remote-app-completion-\(testID)", isDirectory: true)
        let displacedRoot = root.appendingPathExtension("pending")
        let socketPath = "/tmp/peekaboo-remote-app-\(testID).sock"
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: displacedRoot)
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: "\(socketPath).lock")
        }

        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let applicationService = await MainActor.run { BlockingHideApplicationService() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applicationService),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                desktopMutationWatermarkStore: store,
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: true,
                        accessibility: true,
                        appleScript: true,
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

        let fallback = await MainActor.run { RecordingApplicationFallback() }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: client,
                localFallback: fallback)
        }
        let hideTask = Task {
            try await remote.hideApplication(identifier: "dev.stub")
        }
        guard await applicationService.waitUntilHideStarted() else {
            do {
                try await hideTask.value
                Issue.record("Bridge hide completed without reaching the controlled provider")
            } catch {
                Issue.record("Bridge hide failed before provider dispatch: \(error)")
            }
            await host.stop()
            return
        }

        try FileManager.default.moveItem(at: root, to: displacedRoot)
        try Data().write(to: root)
        await applicationService.releaseHide()

        do {
            try await hideTask.value
            Issue.record("Expected indeterminate bridge completion failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.projection.requiresFreshObservation)
        } catch {
            Issue.record("Unexpected lifecycle failure: \(error)")
        }

        let hiddenIdentifiers = await MainActor.run { fallback.hiddenIdentifiers }
        #expect(hiddenIdentifiers.isEmpty)
        await host.stop()
    }

    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.remote-application-tests",
        teamIdentifier: nil,
        processIdentifier: getpid(),
        hostname: nil)
}

@MainActor
private final class PartialInventoryApplicationService: StubApplicationService {
    nonisolated static let warnings = ["Application metadata timed out for PID 41; hidden state is unknown"]

    override func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        let app = ServiceApplicationInfo(
            processIdentifier: 41,
            processStartIdentity: 7,
            bundleIdentifier: nil,
            name: "Poisoned Helper",
            isHidden: false,
            isHiddenKnown: false,
            windowIDs: [],
            metadataWarnings: Self.warnings)
        return UnifiedToolOutput(
            data: ServiceApplicationListData(applications: [app]),
            summary: .init(brief: "1 app", status: .partial, counts: ["applications": 1]),
            metadata: .init(duration: 0, warnings: Self.warnings))
    }
}

@MainActor
private final class ReusedPIDQuitApplicationService: StubApplicationService {
    private let selectedApplication = ServiceApplicationInfo(
        processIdentifier: 4070,
        processStartIdentity: 70,
        bundleIdentifier: "com.apple.TextEdit",
        name: "TextEdit")
    private var currentProcessStartIdentity: UInt64 = 70
    private(set) var receivedQuitRequests: [ApplicationQuitRequest] = []
    private(set) var terminationCount = 0

    override func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        defer { self.currentProcessStartIdentity = 71 }
        return self.selectedApplication.withUniqueTestSelectorProof(for: identifier)
    }

    override func quitApplication(request: ApplicationQuitRequest) async throws -> Bool {
        self.receivedQuitRequests.append(request)
        guard request.expectedIdentity?.processStartIdentity == self.currentProcessStartIdentity else {
            throw PeekabooError.commandFailed("Application PID changed process generation")
        }
        self.terminationCount += 1
        return true
    }
}

@MainActor
private final class BlockingHideApplicationService: StubApplicationService {
    private var hideContinuation: CheckedContinuation<Void, Never>?
    private var hideStarted = false
    private var releaseRequested = false

    override func hideApplication(identifier _: String) async throws {
        if self.releaseRequested {
            self.releaseRequested = false
            return
        }
        await withCheckedContinuation { continuation in
            self.hideContinuation = continuation
            self.hideStarted = true
        }
    }

    func waitUntilHideStarted() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !self.hideStarted, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return self.hideStarted
    }

    func releaseHide() {
        guard let hideContinuation else {
            self.releaseRequested = true
            return
        }
        hideContinuation.resume()
        self.hideContinuation = nil
    }
}

@MainActor
private final class RecordingApplicationFallback:
    ApplicationServiceProtocol,
    ApplicationServiceTargetedActionResultProviding
{
    private let app = ServiceApplicationInfo(
        processIdentifier: 123,
        processStartIdentity: 456,
        bundleIdentifier: "com.apple.finder",
        name: "Finder",
        bundlePath: nil,
        isActive: true,
        isHidden: false,
        windowCount: 1)

    private(set) var hiddenIdentifiers: [String] = []
    private(set) var hideRequests: [ApplicationHideRequest] = []

    var supportsProcessGenerationPinnedApplicationHide: Bool {
        true
    }

    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        UnifiedToolOutput(
            data: ServiceApplicationListData(applications: [self.app]),
            summary: .init(brief: "1 app", status: .success, counts: ["applications": 1]),
            metadata: .init(duration: 0))
    }

    func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        self.app.withUniqueTestSelectorProof(for: identifier)
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

    func hideApplication(identifier: String) async throws {
        self.hiddenIdentifiers.append(identifier)
    }

    func unhideApplication(identifier _: String) async throws {}

    func hideOtherApplications(identifier _: String) async throws {}

    func showAllApplications() async throws {}

    func activateApplicationTargetedActionResult(
        request: ApplicationActivationRequest) async throws -> UIAutomationActionResult<Void>
    {
        try await self.activateApplication(identifier: request.identifier)
        return try UIAutomationActionResult(
            payload: (),
            outcome: Self.applicationOutcome(mode: .foreground),
            targetIdentity: self.targetIdentity())
    }

    func hideApplicationTargetedActionResult(identifier: String) async throws -> UIAutomationActionResult<Void> {
        try await self.hideApplication(identifier: identifier)
        return try UIAutomationActionResult(
            payload: (),
            outcome: Self.applicationOutcome(mode: .background),
            targetIdentity: self.targetIdentity())
    }

    func hideApplicationTargetedActionResult(
        request: ApplicationHideRequest) async throws -> UIAutomationActionResult<Void>
    {
        self.hideRequests.append(request)
        try await self.hideApplication(identifier: request.identifier)
        return try UIAutomationActionResult(
            payload: (),
            outcome: Self.applicationOutcome(mode: .background),
            targetIdentity: DesktopTargetIdentity(processIdentity: request.expectedIdentity))
    }

    func hideOtherApplicationsActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.hideOtherApplications(identifier: identifier)
        return DesktopActionResult(outcome: Self.applicationOutcome(mode: .background))
    }

    func showAllApplicationsActionResult() async throws -> DesktopActionResult<Void> {
        try await self.showAllApplications()
        return DesktopActionResult(outcome: Self.applicationOutcome(mode: .background))
    }

    private func targetIdentity() throws -> DesktopTargetIdentity {
        guard let processIdentity = self.app.processIdentity else {
            throw PeekabooError.commandFailed("Recording application has no process-generation identity")
        }
        return try DesktopTargetIdentity(processIdentity: processIdentity)
    }

    private static func applicationOutcome(
        mode: DesktopActionOutcome.Delivery.Mode) -> DesktopActionOutcome
    {
        .dispatchedUnverified(
            delivery: .init(mechanism: .nativeFramework, mode: mode),
            evidence: .deliveryAccepted)
    }
}
