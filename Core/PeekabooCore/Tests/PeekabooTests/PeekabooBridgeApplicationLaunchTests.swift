import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeApplicationLaunchTests {
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
        let applicationService = await MainActor.run { BlockingLaunchApplicationService() }
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

        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 30)
        let clientTask = Task {
            try await client.launchApplication(
                request: ApplicationLaunchRequest(applicationIdentifier: "com.example.Delayed"))
        }
        try await applicationService.waitUntilLaunchStarted()
        clientTask.cancel()
        do {
            _ = try await clientTask.value
            Issue.record("Expected the disconnected client request to be cancelled")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .internalError)
            #expect(error.operationMayHaveCompleted)
            #expect(error.message.contains("indeterminate"))
            #expect(error.message.contains("do not retry"))
            #expect(PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: error))
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
        let request = ApplicationLaunchRequest(applicationIdentifier: "com.example.Delayed")
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
        try await self.assertLaunchError(.appNotFound("Missing"), expectedCode: .notFound)
    }

    @Test
    func `application launch preserves timeout errors`() async throws {
        try await self.assertLaunchError(.timeout("Launch timed out"), expectedCode: .timeout)
    }

    @MainActor
    private func assertLaunchError(
        _ error: PeekabooError,
        expectedCode: PeekabooBridgeErrorCode) async throws
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
private final class LaunchRecordingApplicationService: StubApplicationService {
    private(set) var launchRequests: [ApplicationLaunchRequest] = []
    var launchError: PeekabooError?

    override func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        if let launchError {
            throw launchError
        }
        self.launchRequests.append(request)
        return try await super.launchApplication(request: request)
    }
}

@MainActor
private final class BlockingLaunchApplicationService: StubApplicationService {
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
