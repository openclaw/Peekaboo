import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeWindowEnumerationTimeoutTests {
    @Test
    @MainActor
    func `bounded AX enrichment releases Bridge request and lane before late worker finishes`() async throws {
        let socketPath = "/tmp/pb-window-enumeration-\(UUID().uuidString).sock"
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: "\(socketPath).lock")
        }

        let windows = BoundedWindowEnumerationService()
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.listWindows, .permissionsStatus])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 1)
        _ = try await client.handshake(client: PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.window-enumeration-timeout-tests",
            teamIdentifier: nil,
            processIdentifier: ProcessInfo.processInfo.processIdentifier))
        let remote = RemoteWindowManagementService(client: client)
        let startedAt = ContinuousClock.now
        let result = try await remote.listWindows(target: .application("Fixture"))
        let elapsed = startedAt.duration(to: .now).timeInterval

        #expect(result.map(\.windowID) == [700])
        #expect(result.first?.mutationIdentity?.ownerProcessIdentifier == 92001)
        #expect(result.first?.mutationIdentity?.ownerProcessStartIdentity == 1)
        #expect(elapsed < 0.5)
        #expect(windows.workerIsStillBlocked)
        #expect(await host.activeRequestCountForTesting() == 0)

        let followUpStartedAt = ContinuousClock.now
        let followUp = try await remote.listWindows(target: .application("Fixture"))
        let followUpElapsed = followUpStartedAt.duration(to: .now).timeInterval
        #expect(followUp.map(\.windowID) == [700])
        #expect(followUpElapsed < 0.5)
        windows.releaseWorker()
        #expect(windows.waitForWorkerFinish())
        #expect(result.map(\.windowID) == [700])
        #expect(await host.activeRequestCountForTesting() == 0)
        await host.stop()
    }
}

@MainActor
private final class BoundedWindowEnumerationService: WindowManagementServiceProtocol {
    private let gate = EnumerationServiceGate()

    var workerIsStillBlocked: Bool {
        self.gate.started && !self.gate.released
    }

    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        let gate = self.gate
        do {
            _ = try await DetachedAXWindowEnumerationCoordinator.run(
                processIdentifier: 92001,
                processStartIdentity: 1,
                timeoutSeconds: 0.05)
            { _ in
                gate.markStarted()
                gate.wait()
                gate.markFinished()
                return DetachedAXWindowEnumerationResult(
                    descriptors: [],
                    focusedWindowID: nil,
                    timedOut: false,
                    incomplete: false,
                    reportedWindowCount: 0)
            }
        } catch CaptureError.detectionTimedOut {
            return [ServiceWindowInfo(
                windowID: 700,
                title: "CG",
                bounds: .zero,
                mutationIdentity: WindowMutationIdentity(
                    windowID: 700,
                    ownerProcessIdentifier: 92001,
                    ownerProcessStartIdentity: 1,
                    capturedBounds: .zero))]
        }
        return []
    }

    func releaseWorker() {
        self.gate.release()
    }

    func waitForWorkerFinish() -> Bool {
        self.gate.waitUntilFinished()
    }

    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target _: WindowTarget) async throws {}
    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}

private final class EnumerationServiceGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let finishedSemaphore = DispatchSemaphore(value: 0)
    private var didStart = false
    private var didRelease = false
    private var didFinish = false

    var started: Bool {
        self.lock.withLock { self.didStart }
    }

    var released: Bool {
        self.lock.withLock { self.didRelease }
    }

    func markStarted() {
        self.lock.withLock { self.didStart = true }
    }

    func wait() {
        self.releaseSemaphore.wait()
    }

    func release() {
        self.lock.withLock { self.didRelease = true }
        self.releaseSemaphore.signal()
    }

    func markFinished() {
        self.lock.withLock { self.didFinish = true }
        self.finishedSemaphore.signal()
    }

    func waitUntilFinished() -> Bool {
        if self.lock.withLock({ self.didFinish }) {
            return true
        }
        return self.finishedSemaphore.wait(timeout: .now() + 1) == .success
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
