import AppKit
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge

struct PeekabooBridgeApplicationLaunchTests {
    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.application-launch-tests",
        teamIdentifier: nil,
        processIdentifier: getpid())

    private func decode(_ data: Data) throws -> PeekabooBridgeResponse {
        try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
    }

    @Test
    func `wait until ready launch uses an extended bridge deadline`() {
        #expect(PeekabooBridgeClient.applicationLaunchRequestTimeout(
            defaultTimeoutSec: 10,
            waitUntilReady: false) == nil)
        #expect(PeekabooBridgeClient.applicationLaunchRequestTimeout(
            defaultTimeoutSec: 10,
            waitUntilReady: true) == 30)
        #expect(PeekabooBridgeClient.applicationLaunchRequestTimeout(
            defaultTimeoutSec: 45,
            waitUntilReady: true) == 45)
        #expect(PeekabooBridgeClient.applicationLaunchRequestTimeout(
            defaultTimeoutSec: 10,
            waitUntilReady: false,
            waitForWindow: true) == 30)
        #expect(PeekabooBridgeClient.applicationRelaunchRequestTimeout(
            defaultTimeoutSec: 10,
            waitSeconds: 2,
            waitUntilReady: false) == 17)
        #expect(PeekabooBridgeClient.applicationRelaunchRequestTimeout(
            defaultTimeoutSec: 10,
            waitSeconds: 2,
            waitUntilReady: true) == 27)
    }

    @Test
    func `handshake hides launch options unsupported by the application service`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: StubApplicationService(
                    supportsApplicationLaunchOptions: false,
                    supportsApplicationRelaunch: false)),
                hostKind: .onDemand,
                allowlistedTeams: [],
                allowlistedBundles: [],
                daemonControl: StubDaemonControl())
        }
        let request = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            client: .init(
                bundleIdentifier: "dev.peeka.cli",
                teamIdentifier: "TEAMID",
                processIdentifier: getpid(),
                hostname: Host.current().name),
            requestedHostKind: .onDemand))

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil)
        let response = try self.decode(responseData)
        guard case let .handshake(handshake) = response else {
            Issue.record("Expected handshake response, got \(response)")
            return
        }

        #expect(!handshake.supportedOperations.contains(.launchApplicationWithOptions))
        #expect(!handshake.supportedOperations.contains(.relaunchApplicationWithOptions))
    }

    @Test
    func `handshake hides launch options from protocol 1_8 clients`() async throws {
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
                protocolVersion: .init(major: 1, minor: 8),
                client: identity,
                requestedHostKind: .gui))

        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .handshake(handshake) = response else {
            Issue.record("Expected handshake response, got \(response)")
            return
        }
        #expect(handshake.negotiatedVersion == .init(major: 1, minor: 8))
        #expect(!handshake.supportedOperations.contains(.launchApplicationWithOptions))
    }

    @Test
    func `current application service advertises safe background no-op semantics`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let request = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            client: .init(
                bundleIdentifier: "dev.peeka.cli",
                teamIdentifier: "TEAMID",
                processIdentifier: getpid(),
                hostname: Host.current().name),
            requestedHostKind: .gui))

        let response = try await self.decode(server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil))
        guard case let .handshake(handshake) = response else {
            Issue.record("Expected handshake response, got \(response)")
            return
        }

        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.safeBackgroundApplicationLaunchNoOp) == true)
    }

    @Test
    @MainActor
    func `identifier-only background launch refuses an unsafe provider without dispatch`() async throws {
        let applications = UnsafeLaunchRecordingApplicationService()
        #expect(!applications.supportsSafeBackgroundApplicationLaunchNoOp)
        let server = PeekabooBridgeServer(
            services: StubServices(applications: applications),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let request = PeekabooBridgeRequest.launchApplicationWithOptions(
            ApplicationLaunchRequest(applicationIdentifier: "Finder"))

        #expect(PeekabooBridgeOperationResultSemantics.contract(for: request) == .init(
            completion: .readOnly,
            targetPolicy: .notApplicable))
        let response = try await self.decode(server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil))
        guard case let .error(envelope) = response else {
            Issue.record("Expected unsafe provider refusal, got \(response)")
            return
        }
        #expect(envelope.code == .operationNotSupported)
        #expect(envelope.message.contains("no-dispatch background launch"))
        #expect(!envelope.operationMayHaveCompleted)
        #expect(applications.launchRequests.isEmpty)
    }

    @Test
    @MainActor
    func `pinned activation receipt round trips through Bridge`() async throws {
        let applications = StubApplicationService()
        let server = PeekabooBridgeServer(
            services: StubServices(applications: applications),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let expectedIdentity = ApplicationProcessIdentity(
            processIdentifier: 123,
            processStartIdentity: 456)
        let request = PeekabooBridgeRequest.activateApplication(.init(
            identifier: "PID:123",
            expectedIdentity: expectedIdentity))

        let response = try await self.decode(server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil))

        guard case .ok = response else {
            Issue.record("Expected activation success, got \(response)")
            return
        }
        #expect(applications.activationRequests == [ApplicationActivationRequest(
            identifier: "PID:123",
            expectedIdentity: expectedIdentity)])
    }

    @Test
    func `legacy application launch preserves foreground dispatch semantics`() async throws {
        let applicationService = await MainActor.run { LaunchRecordingApplicationService() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applicationService),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeRequest.launchApplication(
                PeekabooBridgeAppIdentifierRequest(identifier: "com.example.LegacyApp")))

        let response = try await self.decode(server.decodeAndHandle(requestData, peer: nil))

        guard case .application = response else {
            Issue.record("Expected legacy application response, got \(response)")
            return
        }
        let requests = await MainActor.run { applicationService.launchRequests }
        #expect(requests == [ApplicationLaunchRequest(
            applicationIdentifier: "com.example.LegacyApp",
            activates: true)])
    }

    @Test
    func `application launch options round trip through bridge host`() async throws {
        let applicationService = await MainActor.run { LaunchRecordingApplicationService() }
        let stub = await MainActor.run { StubServices(applications: applicationService) }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: stub,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true })
        }
        let launchRequest = try ApplicationLaunchRequest(
            applicationIdentifier: "com.example.BackgroundApp",
            openURLs: [#require(URL(string: "https://example.com"))],
            activates: false,
            waitUntilReady: true,
            waitForWindow: true,
            createsNewInstance: true)
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeRequest.launchApplicationWithOptions(launchRequest))

        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .application(application) = response else {
            Issue.record("Expected application response, got \(response)")
            return
        }
        #expect(application.processIdentity == ApplicationProcessIdentity(
            processIdentifier: 123,
            processStartIdentity: 456))
        let requests = await MainActor.run { applicationService.launchRequests }
        #expect(requests == [launchRequest])
    }

    @Test
    func `disconnected client leaves host mutation barrier active through actual completion`() async throws {
        let testID = String(UUID().uuidString.prefix(8))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-bridge-mutation-\(testID)", isDirectory: true)
        let socketPath = "/tmp/peekaboo-mut-\(testID).sock"
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: "\(socketPath).lock")
        }
        let store = DesktopMutationWatermarkStore(
            directoryURL: root.appendingPathComponent("state", isDirectory: true))
        let applicationService = await MainActor.run {
            let service = BlockingLaunchApplicationService()
            service.actionOutcome = .confirmedChange(
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                unitCount: .one)
            return service
        }
        let snapshots = await MainActor.run {
            InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applicationService, snapshots: snapshots),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                desktopMutationWatermarkStore: store)
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 30)
        _ = try await client.handshake(client: Self.clientIdentity)
        let clientTask = Task {
            try await client.launchApplication(
                request: ApplicationLaunchRequest(
                    applicationIdentifier: "com.example.Delayed",
                    activates: true))
        }
        try await applicationService.waitUntilLaunchStarted()
        clientTask.cancel()
        do {
            _ = try await clientTask.value
            Issue.record("Expected the disconnected client request to be cancelled")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .responseLost)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.projection.requiresFreshObservation)
            #expect(failure.message.contains("indeterminate"))
            #expect(failure.message.contains("do not retry"))
            #expect(PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: failure))
        } catch {
            Issue.record("Expected response-lost failure, got \(error)")
        }
        try await Self.waitForActiveConnectionCount(0, host: host)

        let firstPendingRead = try #require(store.effectiveWatermark())
        try await Task.sleep(for: .milliseconds(2))
        let secondPendingRead = try #require(store.effectiveWatermark())
        #expect(secondPendingRead > firstPendingRead)
        let interimSnapshotID = try await snapshots.createSnapshot()
        #expect(await snapshots.getMostRecentSnapshot() == nil)

        await applicationService.releaseLaunch()
        try await applicationService.waitUntilLaunchFinished()
        let completionWatermark = try await Self.waitForStableWatermark(store)
        #expect(completionWatermark >= secondPendingRead)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
        #expect(try await snapshots.getUIAutomationSnapshot(snapshotId: interimSnapshotID) != nil)
        await host.stop()
    }

    @Test
    func `barrier completion failure is returned instead of hiding the stale reservation`() async throws {
        let testID = String(UUID().uuidString.prefix(8))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-bridge-completion-\(testID)", isDirectory: true)
        let displacedRoot = root.appendingPathExtension("pending")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: displacedRoot)
        }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let applicationService = await MainActor.run { BlockingLaunchApplicationService() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applicationService),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                desktopMutationWatermarkStore: store)
        }
        let request = ApplicationLaunchRequest(
            applicationIdentifier: "com.example.Delayed",
            activates: true)
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeRequest.launchApplicationWithOptions(request))
        let responseTask = Task { await server.decodeAndHandle(requestData, peer: nil) }
        try await applicationService.waitUntilLaunchStarted()

        try FileManager.default.moveItem(at: root, to: displacedRoot)
        try Data().write(to: root)
        await applicationService.releaseLaunch()
        let response = try await self.decode(responseTask.value)

        guard case let .error(envelope) = response else {
            Issue.record("Expected barrier completion error, got \(response)")
            return
        }
        #expect(envelope.code == .internalError)
        #expect(envelope.message.contains("snapshot safety barrier"))
        #expect(envelope.operationMayHaveCompleted)
        #expect(PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: envelope))

        let pendingDirectory = displacedRoot
            .appendingPathComponent("desktop-mutation-pending", isDirectory: true)
        #expect(try !FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil).isEmpty)

        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: displacedRoot, to: root)
        let followUpRequestData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeRequest.launchApplicationWithOptions(
                ApplicationLaunchRequest(applicationIdentifier: "com.example.FollowUp")))
        let followUpResponse = try await self.decode(server.decodeAndHandle(followUpRequestData, peer: nil))
        guard case .application = followUpResponse else {
            Issue.record("Expected follow-up operation after gate release, got \(followUpResponse)")
            return
        }
    }

    @Test
    func `application launch preserves app not found errors`() async throws {
        try await self.assertLaunchError(PeekabooError.appNotFound("Missing"), expectedCode: .notFound)
    }

    @Test
    func `application launch preserves timeout errors`() async throws {
        try await self.assertLaunchError(PeekabooError.timeout("Launch timed out"), expectedCode: .timeout)
    }

    @Test
    func `background readiness timeout preserves zero-dispatch receipt`() async throws {
        try await self.assertLaunchError(
            ApplicationLifecycleReadOnlyFailureError(.timeout("Window readiness timed out")),
            expectedCode: .timeout,
            expectedContext: ApplicationLifecycleReadOnlyFailureError.bridgeContext)
    }

    @Test
    @MainActor
    func `background lifecycle requests refuse through Bridge before native dispatch`() async throws {
        let coordinationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-platform-truth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: coordinationRoot) }
        var applicationOpenCalls = 0
        var defaultOpenCalls = 0
        var runningInventoryReads = 0
        var relaunchResolutionCalls = 0
        var relaunchQuitCalls = 0
        let applicationService = ApplicationService(
            operationLaneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: coordinationRoot),
            applicationOpenHandler: { _, _, _ in
                applicationOpenCalls += 1
                return NSRunningApplication.current
            },
            defaultApplicationOpenHandler: { _, _ in
                defaultOpenCalls += 1
                return NSRunningApplication.current
            },
            runningApplicationsForURLProvider: { _ in
                runningInventoryReads += 1
                return []
            },
            relaunchTargetResolver: { _ in
                relaunchResolutionCalls += 1
                return ServiceApplicationInfo(
                    processIdentifier: 4321,
                    processStartIdentity: 77,
                    bundleIdentifier: "com.example.Target",
                    name: "Target")
            },
            relaunchQuitHandler: { _ in
                relaunchQuitCalls += 1
                return .init(requestAccepted: true, terminated: true)
            })
        let server = PeekabooBridgeServer(
            services: StubServices(applications: applicationService),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            daemonControl: StubDaemonControl())
        let target = try #require(URL(string: "https://example.com/bridge-refusal"))
        let launchRequests: [PeekabooBridgeRequest] = [
            .launchApplicationWithOptions(ApplicationLaunchRequest(applicationIdentifier: "Finder")),
            .launchApplicationWithOptions(ApplicationLaunchRequest(
                applicationIdentifier: "Finder",
                openURLs: [target])),
            .launchApplicationWithOptions(ApplicationLaunchRequest(
                applicationIdentifier: "Finder",
                createsNewInstance: true)),
            .launchApplicationWithOptions(ApplicationLaunchRequest(openURLs: [target])),
            .relaunchApplicationWithOptions(ApplicationRelaunchRequest(
                targetIdentifier: "PID:4321",
                expectedTargetIdentity: ApplicationProcessIdentity(
                    processIdentifier: 4321,
                    processStartIdentity: 77),
                launchRequest: ApplicationLaunchRequest(applicationIdentifier: "Finder"),
                waitSeconds: 0)),
        ]

        for request in launchRequests {
            let responseData = try await server.decodeAndHandle(
                JSONEncoder.peekabooBridgeEncoder().encode(request),
                peer: nil)
            guard case let .error(envelope) = try self.decode(responseData) else {
                Issue.record("Expected Bridge refusal for \(request.operation.rawValue)")
                continue
            }
            #expect(envelope.code == .internalError)
            #expect(envelope.message.contains("refused before"))
            #expect(envelope.context == ApplicationLifecycleRefusalError.backgroundLaunchContext)
            #expect(!envelope.operationMayHaveCompleted)
        }

        #expect(runningInventoryReads == 1)
        #expect(applicationOpenCalls == 0)
        #expect(defaultOpenCalls == 0)
        #expect(relaunchResolutionCalls == 0)
        #expect(relaunchQuitCalls == 0)
    }

    @Test
    @MainActor
    func `Bridge relaunch refuses a launch bundle that differs from the pinned quit target`() async throws {
        var applicationOpenCalls = 0
        var relaunchResolutionCalls = 0
        var relaunchQuitCalls = 0
        let applicationService = ApplicationService(
            applicationOpenHandler: { _, _, _ in
                applicationOpenCalls += 1
                return NSRunningApplication.current
            },
            relaunchTargetResolver: { _ in
                relaunchResolutionCalls += 1
                return ServiceApplicationInfo(
                    processIdentifier: 4321,
                    processStartIdentity: 77,
                    bundleIdentifier: "com.example.Unrelated",
                    name: "Unrelated",
                    bundlePath: "/Applications/Unrelated.app")
            },
            relaunchQuitHandler: { _ in
                relaunchQuitCalls += 1
                return .init(requestAccepted: true, terminated: true)
            },
            processStartIdentityProvider: { _ in 77 })
        let server = PeekabooBridgeServer(
            services: StubServices(applications: applicationService),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let request = PeekabooBridgeRequest.relaunchApplicationWithOptions(.init(
            targetIdentifier: "PID:4321",
            expectedTargetIdentity: .init(processIdentifier: 4321, processStartIdentity: 77),
            launchRequest: .init(applicationIdentifier: "Finder", activates: true),
            waitSeconds: 0))

        do {
            _ = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                try await server.handleAuthorized(
                    request,
                    peer: nil,
                    permissions: .init(screenRecording: true, accessibility: true, postEvent: true))
            }
            Issue.record("Expected Bridge to preserve the mismatched relaunch refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .invalidRequest)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.targetReceipt == .init(processIdentifier: 4321, processStartIdentity: 77))
        }

        #expect(relaunchResolutionCalls == 1)
        #expect(relaunchQuitCalls == 0)
        #expect(applicationOpenCalls == 0)
    }

    @Test
    @MainActor
    func `legacy Bridge unhide refuses before application service dispatch`() async throws {
        #expect(!PeekabooBridgeOperation.remoteDefaultAllowlist.contains(.unhideApplication))
        let applicationService = UnhideRecordingApplicationService()
        let server = PeekabooBridgeServer(
            services: StubServices(applications: applicationService),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: PeekabooBridgeOperation.remoteDefaultAllowlist.union([.unhideApplication]))
        let request = PeekabooBridgeRequest.unhideApplication(
            PeekabooBridgeAppIdentifierRequest(identifier: "Finder"))

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil)
        guard case let .error(envelope) = try self.decode(responseData) else {
            Issue.record("Expected legacy Bridge unhide refusal")
            return
        }
        #expect(envelope.context == ApplicationLifecycleRefusalError.unhideContext)
        #expect(!envelope.operationMayHaveCompleted)
        #expect(applicationService.unhideCalls == 0)
    }

    @MainActor
    private func assertLaunchError(
        _ error: any Error,
        expectedCode: PeekabooBridgeErrorCode,
        expectedContext: String? = nil) async throws
    {
        let applicationService = LaunchRecordingApplicationService()
        applicationService.launchError = error
        let stub = StubServices(applications: applicationService)
        let server = PeekabooBridgeServer(
            services: stub,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeRequest.launchApplicationWithOptions(
                ApplicationLaunchRequest(applicationIdentifier: "Missing")))

        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case let .error(envelope) = response else {
            Issue.record("Expected bridge error response, got \(response)")
            return
        }
        #expect(envelope.code == expectedCode)
        #expect(!envelope.message.isEmpty)
        if let expectedContext {
            #expect(envelope.context == expectedContext)
        }
        #expect(!envelope.operationMayHaveCompleted)
    }

    private static func waitForStableWatermark(
        _ store: DesktopMutationWatermarkStore) async throws -> Date
    {
        for _ in 0..<100 {
            let first = try #require(store.effectiveWatermark())
            try await Task.sleep(for: .milliseconds(5))
            let second = try #require(store.effectiveWatermark())
            if first == second {
                return second
            }
        }
        throw PeekabooError.timeout("Mutation barrier did not settle")
    }

    private static func waitForActiveConnectionCount(
        _ expectedCount: Int,
        host: PeekabooBridgeHost) async throws
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await host.activeConnectionCountForTesting() != expectedCount {
            guard clock.now < deadline else {
                throw PeekabooError.timeout("Bridge connection did not reach the expected state")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private class LaunchRecordingApplicationService: StubApplicationService {
    override var supportsSafeBackgroundApplicationLaunchNoOp: Bool {
        true
    }

    private(set) var launchRequests: [ApplicationLaunchRequest] = []
    var launchError: (any Error)?

    override func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        if let launchError {
            throw launchError
        }
        self.launchRequests.append(request)
        return try await super.launchApplication(request: request)
    }
}

@MainActor
private final class UnsafeLaunchRecordingApplicationService: LaunchRecordingApplicationService {
    override var supportsSafeBackgroundApplicationLaunchNoOp: Bool {
        false
    }
}

@MainActor
private final class BlockingLaunchApplicationService: StubApplicationService {
    override var supportsSafeBackgroundApplicationLaunchNoOp: Bool {
        true
    }

    private var launchContinuation: CheckedContinuation<Void, Never>?
    private var launchStarted = false
    private var launchFinished = false
    private var launchCount = 0

    override func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        self.launchCount += 1
        if self.launchCount == 1 {
            self.launchStarted = true
            await withCheckedContinuation { continuation in
                self.launchContinuation = continuation
            }
        }
        let application = try await super.launchApplication(request: request)
        self.launchFinished = true
        return application
    }

    func waitUntilLaunchStarted() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !self.launchStarted {
            guard clock.now < deadline else {
                throw PeekabooError.timeout("Application launch did not start")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseLaunch() {
        self.launchContinuation?.resume()
        self.launchContinuation = nil
    }

    func waitUntilLaunchFinished() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !self.launchFinished {
            guard clock.now < deadline else {
                throw PeekabooError.timeout("Application launch did not finish")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class UnhideRecordingApplicationService: StubApplicationService {
    private(set) var unhideCalls = 0

    override func unhideApplication(identifier _: String) async throws {
        self.unhideCalls += 1
    }
}
