import Foundation
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import Testing

struct RemoteApplicationServiceTests {
    @Test
    func `remote running check propagates transport failure instead of returning false`() async {
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(
                    socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
                    requestTimeoutSec: 0.1))
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

        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
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
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
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
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
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
        let applications = await MainActor.run { StubApplicationService() }
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

        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
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
            processIdentifier: 123,
            processStartIdentity: 456))
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

        let directClient = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        try await directClient.hideApplication(identifier: "Finder")

        let fallback = await MainActor.run { RecordingApplicationFallback() }
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
                localFallback: fallback)
        }

        try await remote.hideApplication(identifier: "Finder")
        let bridgedIdentifiers = await MainActor.run { bridgedApplications.hiddenIdentifiers }
        let hiddenIdentifiers = await MainActor.run { fallback.hiddenIdentifiers }
        #expect(bridgedIdentifiers == ["Finder", "Finder"])
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
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
                localFallback: fallback)
        }
        let hideTask = Task {
            try await remote.hideApplication(identifier: "Finder")
        }
        await applicationService.waitUntilHideStarted()

        try FileManager.default.moveItem(at: root, to: displacedRoot)
        try Data().write(to: root)
        await applicationService.releaseHide()

        do {
            try await hideTask.value
            Issue.record("Expected indeterminate bridge completion failure")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .internalError)
            #expect(envelope.operationMayHaveCompleted)
        }

        let hiddenIdentifiers = await MainActor.run { fallback.hiddenIdentifiers }
        #expect(hiddenIdentifiers.isEmpty)
        await host.stop()
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

    override func findApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        defer { self.currentProcessStartIdentity = 71 }
        return self.selectedApplication
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
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var hideStarted = false

    override func hideApplication(identifier _: String) async throws {
        self.hideStarted = true
        self.startWaiters.forEach { $0.resume() }
        self.startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            self.hideContinuation = continuation
        }
    }

    func waitUntilHideStarted() async {
        guard !self.hideStarted else { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func releaseHide() {
        self.hideContinuation?.resume()
        self.hideContinuation = nil
    }
}

@MainActor
private final class RecordingApplicationFallback: ApplicationServiceProtocol {
    private let app = ServiceApplicationInfo(
        processIdentifier: 123,
        bundleIdentifier: "com.apple.finder",
        name: "Finder",
        bundlePath: nil,
        isActive: true,
        isHidden: false,
        windowCount: 1)

    private(set) var hiddenIdentifiers: [String] = []

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

    func hideApplication(identifier: String) async throws {
        self.hiddenIdentifiers.append(identifier)
    }

    func unhideApplication(identifier _: String) async throws {}

    func hideOtherApplications(identifier _: String) async throws {}

    func showAllApplications() async throws {}
}
