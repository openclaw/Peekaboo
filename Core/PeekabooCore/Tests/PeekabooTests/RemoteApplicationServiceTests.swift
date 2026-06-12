import Foundation
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import Testing

struct RemoteApplicationServiceTests {
    @Test
    func `lifecycle falls back when on-demand bridge lacks AppleScript permission`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-app-fallback-\(UUID().uuidString).sock"
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
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
        do {
            try await directClient.hideApplication(identifier: "Finder")
            Issue.record("Expected bridge AppleScript permission denial")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .permissionDenied)
            #expect(envelope.permission == .appleScript)
        }

        let fallback = await MainActor.run { RecordingApplicationFallback() }
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
                localFallback: fallback)
        }

        try await remote.hideApplication(identifier: "Finder")
        let hiddenIdentifiers = await MainActor.run { fallback.hiddenIdentifiers }
        #expect(hiddenIdentifiers == ["Finder"])
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
