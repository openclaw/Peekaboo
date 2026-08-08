import Foundation
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import Testing

struct RemoteApplicationServiceTests {
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
