import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeWindowMutationIdentityTests {
    private let identity = WindowMutationIdentity(
        windowID: 77,
        ownerProcessIdentifier: 420,
        ownerProcessStartIdentity: 9001,
        capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100))

    @Test
    func `window mutation payloads round trip pinned identity`() throws {
        let requests: [PeekabooBridgeRequest] = [
            .moveWindow(.init(target: .windowId(77), expectedIdentity: self.identity, position: .zero)),
            .resizeWindow(.init(target: .windowId(77), expectedIdentity: self.identity, size: .zero)),
            .setWindowBounds(.init(target: .windowId(77), expectedIdentity: self.identity, bounds: .zero)),
            .closeWindow(.init(target: .windowId(77), expectedIdentity: self.identity)),
            .backgroundCloseWindow(.init(target: .windowId(77), expectedIdentity: self.identity)),
            .minimizeWindow(.init(target: .windowId(77), expectedIdentity: self.identity)),
            .restoreWindow(.init(target: .windowId(77), expectedIdentity: self.identity)),
            .maximizeWindow(.init(target: .windowId(77), expectedIdentity: self.identity)),
        ]
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        let decoder = JSONDecoder.peekabooBridgeDecoder()

        for request in requests {
            let decoded = try decoder.decode(PeekabooBridgeRequest.self, from: encoder.encode(request))
            #expect(decoded.pinnedWindowMutation?.identity == self.identity)
            #expect(decoded.pinnedWindowMutation?.target.description == "windowId(77)")
        }
    }

    @Test
    func `legacy payload without identity remains decodable`() throws {
        let data = Data(
            """
            {"target":{"kind":"windowId","windowId":77}}
            """.utf8)

        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeWindowTargetRequest.self,
            from: data)

        #expect(decoded.target.description == "windowId(77)")
        #expect(decoded.expectedIdentity == nil)
    }

    @Test
    func `legacy decoder ignores pinned identity field`() throws {
        struct LegacyTargetRequest: Decodable {
            let target: WindowTarget
        }
        let payload = PeekabooBridgeWindowTargetRequest(
            target: .windowId(77),
            expectedIdentity: self.identity)

        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
            LegacyTargetRequest.self,
            from: JSONEncoder.peekabooBridgeEncoder().encode(payload))

        #expect(decoded.target.description == "windowId(77)")
    }

    @Test
    func `receipt-requiring mutations are advertised only to compatible clients`() {
        let operations: Set<PeekabooBridgeOperation> = [
            .moveWindow,
            .resizeWindow,
            .setWindowBounds,
            .closeWindow,
            .backgroundCloseWindow,
            .minimizeWindow,
            .restoreWindow,
            .maximizeWindow,
        ]

        #expect(PeekabooBridgeOperation.compatible(
            operations,
            with: .init(major: 1, minor: 15)).isEmpty)
        #expect(PeekabooBridgeOperation.compatible(
            operations,
            with: .init(major: 1, minor: 17)).isEmpty)
        #expect(PeekabooBridgeOperation.compatible(
            operations,
            with: .init(major: 1, minor: 18)) == operations)
    }

    @Test
    @MainActor
    func `current host rejects legacy receipts without capture-time bounds`() async throws {
        let windows = LegacyWindowMutationService()
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.moveWindow])
        let legacyIdentity = WindowMutationIdentity(
            windowID: 77,
            ownerProcessIdentifier: 420,
            ownerProcessStartIdentity: 9001)
        let request = PeekabooBridgeRequest.moveWindow(.init(
            target: .windowId(77),
            expectedIdentity: legacyIdentity,
            position: CGPoint(x: 3, y: 4)))

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil)
        guard case let .error(error) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: responseData)
        else {
            Issue.record("Expected bounds-less receipt to fail")
            return
        }
        #expect(error.code == .invalidRequest)
        #expect(error.message.contains("capture-time bounds"))
        #expect(await windows.pinnedMutationCount == 0)
    }

    @Test
    @MainActor
    func `same process and window ID with changed bounds rejects every mutation`() async throws {
        let windows = LegacyWindowMutationService()
        let operations: Set<PeekabooBridgeOperation> = [
            .moveWindow,
            .resizeWindow,
            .setWindowBounds,
            .closeWindow,
            .backgroundCloseWindow,
            .minimizeWindow,
            .restoreWindow,
            .maximizeWindow,
        ]
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: operations,
            windowOwnerProcessIdentifierProvider: { _ in 420 },
            windowBoundsProvider: { _ in CGRect(x: 20, y: 30, width: 640, height: 480) },
            processStartIdentityProvider: { _ in 9001 })
        let requests: [PeekabooBridgeRequest] = [
            .moveWindow(.init(target: .windowId(77), expectedIdentity: self.identity, position: .zero)),
            .resizeWindow(.init(target: .windowId(77), expectedIdentity: self.identity, size: .zero)),
            .setWindowBounds(.init(target: .windowId(77), expectedIdentity: self.identity, bounds: .zero)),
            .closeWindow(.init(target: .windowId(77), expectedIdentity: self.identity)),
            .backgroundCloseWindow(.init(target: .windowId(77), expectedIdentity: self.identity)),
            .minimizeWindow(.init(target: .windowId(77), expectedIdentity: self.identity)),
            .restoreWindow(.init(target: .windowId(77), expectedIdentity: self.identity)),
            .maximizeWindow(.init(target: .windowId(77), expectedIdentity: self.identity)),
        ]
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        let decoder = JSONDecoder.peekabooBridgeDecoder()

        for request in requests {
            let response = try await decoder.decode(
                PeekabooBridgeResponse.self,
                from: server.decodeAndHandle(encoder.encode(request), peer: nil))
            guard case let .error(error) = response else {
                Issue.record("Expected changed-bounds \(request.operation.rawValue) to fail")
                continue
            }
            #expect(error.code == .invalidRequest)
        }
        #expect(await windows.pinnedMutationCount == 0)
    }

    @Test
    @MainActor
    func `current host rejects every receipt-less window mutation without dispatch`() async throws {
        let windows = LegacyWindowMutationService()
        let operations: Set<PeekabooBridgeOperation> = [
            .moveWindow,
            .resizeWindow,
            .setWindowBounds,
            .closeWindow,
            .backgroundCloseWindow,
            .minimizeWindow,
            .restoreWindow,
            .maximizeWindow,
        ]
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: operations)
        let requests: [PeekabooBridgeRequest] = [
            .moveWindow(.init(target: .windowId(77), position: CGPoint(x: 3, y: 4))),
            .resizeWindow(.init(target: .windowId(77), size: CGSize(width: 3, height: 4))),
            .setWindowBounds(.init(target: .windowId(77), bounds: CGRect(x: 1, y: 2, width: 3, height: 4))),
            .closeWindow(.init(target: .windowId(77))),
            .backgroundCloseWindow(.init(target: .windowId(77))),
            .minimizeWindow(.init(target: .windowId(77))),
            .restoreWindow(.init(target: .windowId(77))),
            .maximizeWindow(.init(target: .windowId(77))),
        ]

        for request in requests {
            let responseData = try await server.decodeAndHandle(
                JSONEncoder.peekabooBridgeEncoder().encode(request),
                peer: nil)
            guard case let .error(error) = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self,
                from: responseData)
            else {
                Issue.record("Expected receipt-less \(request.operation.rawValue) to fail")
                continue
            }
            #expect(error.code == .invalidRequest)
            #expect(error.message.contains("mutation receipt"))
        }
        #expect(await windows.legacyMutationCount == 0)
        #expect(await windows.pinnedMutationCount == 0)
    }

    @Test
    @MainActor
    func `minimized identity may dispatch when WindowServer omits its entry`() async throws {
        let minimizedIdentity = WindowMutationIdentity(
            windowID: 77,
            ownerProcessIdentifier: 420,
            ownerProcessStartIdentity: 9001,
            capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            isMinimized: true)
        let windows = PinnedCloseWindowMutationService()
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.backgroundCloseWindow],
            windowOwnerProcessIdentifierProvider: { _ in nil },
            processStartIdentityProvider: { _ in 9001 })
        let request = PeekabooBridgeRequest.backgroundCloseWindow(.init(
            target: .windowId(77),
            expectedIdentity: minimizedIdentity))

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil)
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: responseData)

        guard case .ok = response else {
            Issue.record("Expected minimized pinned close to reach the service")
            return
        }
        #expect(await windows.closeCount == 1)
    }

    @Test
    @MainActor
    func `minimized restore receipt reaches service when WindowServer omits its entry`() async throws {
        let identity = WindowMutationIdentity(
            windowID: 77,
            ownerProcessIdentifier: 420,
            ownerProcessStartIdentity: 9001,
            capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            isMinimized: true)
        let windows = LegacyWindowMutationService()
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.restoreWindow],
            windowOwnerProcessIdentifierProvider: { _ in nil },
            windowBoundsProvider: { _ in nil },
            processStartIdentityProvider: { _ in 9001 })
        let request = PeekabooBridgeRequest.restoreWindow(.init(
            target: .windowId(77),
            expectedIdentity: identity))

        let response = try await JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: server.decodeAndHandle(
                JSONEncoder.peekabooBridgeEncoder().encode(request),
                peer: nil))

        guard case .ok = response else {
            Issue.record("Expected minimized restore to reach pinned service")
            return
        }
        #expect(await windows.pinnedMutationCount == 1)
        #expect(await windows.legacyMutationCount == 0)
    }

    @Test
    @MainActor
    func `queued mutation rejects same PID generation reuse before dispatch`() async throws {
        let currentIdentity = LockedWindowMutationState(ownerPID: 420, processStartIdentity: 9001)
        let windows = BlockingWindowMutationService()
        let services = StubServices(windows: windows)
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.moveWindow],
            windowOwnerProcessIdentifierProvider: { _ in currentIdentity.ownerPID },
            windowBoundsProvider: { _ in CGRect(x: 0, y: 0, width: 100, height: 100) },
            processStartIdentityProvider: { _ in currentIdentity.processStartIdentity })
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        let decoder = JSONDecoder.peekabooBridgeDecoder()

        let first = PeekabooBridgeRequest.moveWindow(.init(
            target: .windowId(77),
            expectedIdentity: self.identity,
            position: CGPoint(x: 1, y: 1)))
        let firstData = try encoder.encode(first)
        let firstTask = Task { await server.decodeAndHandle(firstData, peer: nil) }
        await windows.waitUntilLegacyMutationStarted()

        let queued = PeekabooBridgeRequest.moveWindow(.init(
            target: .windowId(77),
            expectedIdentity: self.identity,
            position: CGPoint(x: 2, y: 2)))
        let queuedData = try encoder.encode(queued)
        let queuedTask = Task { await server.decodeAndHandle(queuedData, peer: nil) }
        try await Task.sleep(for: .milliseconds(20))
        currentIdentity.processStartIdentity = 9002
        await windows.releaseLegacyMutation()

        _ = await firstTask.value
        let queuedResponse = try await decoder.decode(PeekabooBridgeResponse.self, from: queuedTask.value)
        guard case let .error(error) = queuedResponse else {
            Issue.record("Expected recycled queued mutation to fail")
            return
        }
        #expect(error.code == .invalidRequest)
        #expect(await windows.pinnedMutationCount == 0)
    }
}

private final class LockedWindowMutationState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOwnerPID: pid_t
    private var storedProcessStartIdentity: UInt64

    init(ownerPID: pid_t, processStartIdentity: UInt64) {
        self.storedOwnerPID = ownerPID
        self.storedProcessStartIdentity = processStartIdentity
    }

    var ownerPID: pid_t {
        self.lock.withLock { self.storedOwnerPID }
    }

    var processStartIdentity: UInt64 {
        get { self.lock.withLock { self.storedProcessStartIdentity } }
        set { self.lock.withLock { self.storedProcessStartIdentity = newValue } }
    }
}

private actor BlockingWindowMutationService: WindowManagementServiceProtocol {
    private var legacyMutationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var pinnedMutationCount = 0

    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {
        self.legacyMutationStarted = true
        self.startWaiters.forEach { $0.resume() }
        self.startWaiters.removeAll()
        await withCheckedContinuation { self.releaseContinuation = $0 }
    }

    func moveWindow(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGPoint) async throws
    {
        guard !self.legacyMutationStarted else {
            self.pinnedMutationCount += 1
            return
        }
        self.legacyMutationStarted = true
        self.startWaiters.forEach { $0.resume() }
        self.startWaiters.removeAll()
        await withCheckedContinuation { self.releaseContinuation = $0 }
    }

    func waitUntilLegacyMutationStarted() async {
        guard !self.legacyMutationStarted else { return }
        await withCheckedContinuation { self.startWaiters.append($0) }
    }

    func releaseLegacyMutation() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }

    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func restoreWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target _: WindowTarget) async throws {}
    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        []
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}

private actor LegacyWindowMutationService: WindowManagementServiceProtocol {
    private(set) var legacyMutationCount = 0
    private(set) var pinnedMutationCount = 0

    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {
        self.legacyMutationCount += 1
    }

    func moveWindow(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGPoint) async throws
    {
        self.pinnedMutationCount += 1
    }

    func closeWindow(target _: WindowTarget) async throws {
        self.legacyMutationCount += 1
    }

    func closeWindow(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        allowForegroundFallback _: Bool) async throws
    {
        self.pinnedMutationCount += 1
    }

    func minimizeWindow(target _: WindowTarget) async throws {
        self.legacyMutationCount += 1
    }

    func minimizeWindow(target _: WindowTarget, expectedIdentity _: WindowMutationIdentity) async throws {
        self.pinnedMutationCount += 1
    }

    func restoreWindow(target _: WindowTarget) async throws {
        self.legacyMutationCount += 1
    }

    func restoreWindow(target _: WindowTarget, expectedIdentity _: WindowMutationIdentity) async throws {
        self.pinnedMutationCount += 1
    }

    func maximizeWindow(target _: WindowTarget) async throws {
        self.legacyMutationCount += 1
    }

    func maximizeWindow(target _: WindowTarget, expectedIdentity _: WindowMutationIdentity) async throws {
        self.pinnedMutationCount += 1
    }

    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {
        self.legacyMutationCount += 1
    }

    func resizeWindow(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGSize) async throws
    {
        self.pinnedMutationCount += 1
    }

    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {
        self.legacyMutationCount += 1
    }

    func setWindowBounds(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        bounds _: CGRect) async throws
    {
        self.pinnedMutationCount += 1
    }

    func focusWindow(target _: WindowTarget) async throws {}
    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        []
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}

private actor PinnedCloseWindowMutationService: WindowManagementServiceProtocol {
    private(set) var closeCount = 0

    func closeWindow(target _: WindowTarget) async throws {}

    func closeWindow(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        allowForegroundFallback _: Bool) async throws
    {
        self.closeCount += 1
    }

    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target _: WindowTarget) async throws {}
    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        []
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}
