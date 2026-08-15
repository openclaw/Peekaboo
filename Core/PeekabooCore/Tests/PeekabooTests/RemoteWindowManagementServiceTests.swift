import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct RemoteWindowManagementServiceTests {
    private let identity = WindowMutationIdentity(
        windowID: 77,
        ownerProcessIdentifier: 420,
        ownerProcessStartIdentity: 9001,
        capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100))

    @Test
    func `capable remote preserves every window mutation outcome through protocol 1 23`() async throws {
        let socketPath = "/tmp/peekaboo-remote-window-outcome-\(UUID().uuidString).sock"
        let expected = DesktopActionOutcomeFixtures.canonicalOutcomes[0]
        let windows = RemoteWindowMutationFixture(identity: self.identity, actionOutcome: expected)
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: Self.allowedOperations,
            windowOwnerProcessIdentifierProvider: { _ in 420 },
            windowBoundsProvider: { _ in CGRect(x: 0, y: 0, width: 100, height: 100) },
            processStartIdentityProvider: { _ in 9001 })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let remote = RemoteWindowManagementService(
            client: client,
            supportsBackgroundClose: true,
            supportsPinnedWindowMutations: true,
            supportsWindowRestore: true)
        let target = WindowTarget.windowId(self.identity.windowID)
        let outcomes = try await [
            remote.closeWindowResult(
                target: target,
                expectedIdentity: self.identity,
                allowForegroundFallback: false),
            remote.minimizeWindowResult(target: target, expectedIdentity: self.identity),
            remote.restoreWindowResult(target: target, expectedIdentity: self.identity),
            remote.maximizeWindowResult(target: target, expectedIdentity: self.identity),
            remote.moveWindowResult(target: target, expectedIdentity: self.identity, to: .zero),
            remote.resizeWindowResult(target: target, expectedIdentity: self.identity, to: .zero),
            remote.setWindowBoundsResult(target: target, expectedIdentity: self.identity, bounds: .zero),
        ]

        #expect(outcomes.allSatisfy { $0.outcome == expected.routed(to: .bridge) })
        let compatibilityOutcome: DesktopActionOutcome? = try await remote.moveWindowWithOutcome(
            target: target,
            expectedIdentity: self.identity,
            to: .zero)
        #expect(compatibilityOutcome == expected.routed(to: .bridge))
        let bridgeCompatibilityOutcome: DesktopActionOutcome? = try await client.moveWindowWithOutcome(
            target: target,
            expectedIdentity: self.identity,
            to: .zero)
        #expect(bridgeCompatibilityOutcome == expected.routed(to: .bridge))
        for expectedOutcome in DesktopActionOutcomeFixtures.canonicalOutcomes {
            await windows.setActionOutcome(expectedOutcome)
            let carried = try await remote.moveWindowResult(
                target: target,
                expectedIdentity: self.identity,
                to: CGPoint(x: 12, y: 34))
            #expect(carried.outcome == expectedOutcome.routed(to: .bridge))
        }
        await windows.setActionOutcome(nil)
        #expect(try await remote.moveWindowResult(
            target: target,
            expectedIdentity: self.identity,
            to: CGPoint(x: 56, y: 78)).outcome == nil)
        await host.stop()
    }

    @Test
    func `legacy negotiated remote returns nil instead of fabricating window outcomes`() async throws {
        let socketPath = "/tmp/peekaboo-remote-window-outcome-legacy-\(UUID().uuidString).sock"
        let legacyVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 22)
        let windows = RemoteWindowMutationFixture(
            identity: self.identity,
            actionOutcome: DesktopActionOutcomeFixtures.canonicalOutcomes[0])
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: legacyVersion...legacyVersion,
            allowedOperations: Self.allowedOperations,
            windowOwnerProcessIdentifierProvider: { _ in 420 },
            windowBoundsProvider: { _ in CGRect(x: 0, y: 0, width: 100, height: 100) },
            processStartIdentityProvider: { _ in 9001 })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity, protocolVersion: legacyVersion)
        let remote = RemoteWindowManagementService(
            client: client,
            supportsPinnedWindowMutations: true)
        let outcome = try await remote.moveWindowResult(
            target: .windowId(self.identity.windowID),
            expectedIdentity: self.identity,
            to: CGPoint(x: 12, y: 34))

        #expect(outcome.outcome == nil)
        #expect(await windows.pinnedMutations.map(\.operation) == ["move"])
        await host.stop()
    }

    @Test
    func `legacy mutation overloads resolve and dispatch pinned identities`() async throws {
        let socketPath = "/tmp/peekaboo-remote-window-pinning-\(UUID().uuidString).sock"
        let windows = RemoteWindowMutationFixture(identity: self.identity)
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: Self.allowedOperations,
            windowOwnerProcessIdentifierProvider: { _ in 420 },
            windowBoundsProvider: { _ in CGRect(x: 0, y: 0, width: 100, height: 100) },
            processStartIdentityProvider: { _ in 9001 })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let remote = RemoteWindowManagementService(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
            supportsBackgroundClose: true,
            supportsPinnedWindowMutations: true,
            supportsWindowRestore: true)
        try await remote.closeWindow(target: .title("Fixture"))
        try await remote.closeWindow(target: .title("Fixture"), allowForegroundFallback: true)
        try await remote.minimizeWindow(target: .title("Fixture"))
        try await remote.restoreWindow(target: .title("Fixture"))
        try await remote.maximizeWindow(target: .title("Fixture"))
        try await remote.moveWindow(target: .title("Fixture"), to: CGPoint(x: 1, y: 2))
        try await remote.resizeWindow(target: .title("Fixture"), to: CGSize(width: 3, height: 4))
        try await remote.setWindowBounds(
            target: .title("Fixture"),
            bounds: CGRect(x: 5, y: 6, width: 7, height: 8))

        let legacyMutations = await windows.legacyMutations
        let pinnedMutations = await windows.pinnedMutations
        #expect(legacyMutations.isEmpty)
        #expect(pinnedMutations.map(\.operation) == [
            "background-close",
            "close",
            "minimize",
            "restore",
            "maximize",
            "move",
            "resize",
            "set-bounds",
        ])
        #expect(pinnedMutations.allSatisfy { $0.target == "windowId(77)" })
        #expect(pinnedMutations.allSatisfy { $0.identity == self.identity })
        await host.stop()
    }

    @Test
    func `default close remains background-only while explicit foreground fallback propagates`() async throws {
        let socketPath = "/tmp/peekaboo-remote-window-close-compat-\(UUID().uuidString).sock"
        let windows = RemoteWindowMutationFixture(identity: self.identity)
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.listWindows, .closeWindow],
            windowOwnerProcessIdentifierProvider: { _ in 420 },
            windowBoundsProvider: { _ in CGRect(x: 0, y: 0, width: 100, height: 100) },
            processStartIdentityProvider: { _ in 9001 })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let remote = RemoteWindowManagementService(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
            supportsBackgroundClose: false,
            supportsPinnedWindowMutations: true)
        do {
            try await remote.closeWindow(target: .title("Fixture"))
            Issue.record("Expected default background close to require the advertised capability")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .operationNotSupported)
        }
        try await remote.closeWindow(target: .title("Fixture"), allowForegroundFallback: true)
        #expect(await windows.pinnedMutations.map(\.operation) == ["close"])
        await host.stop()
    }

    @Test
    func `legacy read-only window operations do not require pinned mutation support`() async throws {
        let socketPath = "/tmp/peekaboo-remote-window-readonly-\(UUID().uuidString).sock"
        let windows = RemoteWindowMutationFixture(identity: self.identity)
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.listWindows, .focusWindow],
            windowOwnerProcessIdentifierProvider: { _ in 420 },
            windowBoundsProvider: { _ in CGRect(x: 0, y: 0, width: 100, height: 100) },
            processStartIdentityProvider: { _ in 9001 })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let remote = RemoteWindowManagementService(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
            supportsPinnedWindowMutations: false)
        let result = try await remote.listWindows(target: .title("Fixture"))
        try await remote.focusWindow(target: .windowId(77))

        #expect(result.map(\.windowID) == [77])
        #expect(await windows.focusedTargets == ["windowId(77)"])
        await host.stop()
    }

    @Test
    func `protocol 1 28 focus-only host does not require window enumeration`() async throws {
        let socketPath = "/tmp/peekaboo-remote-window-focus-only-\(UUID().uuidString).sock"
        let windows = RemoteWindowMutationFixture(identity: self.identity)
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: ClosedRange(uncheckedBounds: (
                lower: PeekabooBridgeConstants.supportedProtocolRange.lowerBound,
                upper: PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion)),
            allowedOperations: [.focusWindow])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(
            client: PeekabooBridgeClientIdentity(
                bundleIdentifier: "dev.peekaboo.focus-only-tests",
                teamIdentifier: nil,
                processIdentifier: getpid()))
        let remote = RemoteWindowManagementService(
            client: client,
            supportsPinnedWindowMutations: false)
        try await remote.focusWindow(target: .windowId(77))

        #expect(await windows.listCount == 0)
        #expect(await windows.focusedTargets == ["windowId(77)"])
        await host.stop()
    }

    @Test
    func `protocol 1 29 does not advertise focus without window enumeration`() async throws {
        let socketPath = "/tmp/peekaboo-remote-window-focus-dependency-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: StubServices(windows: RemoteWindowMutationFixture(identity: self.identity)),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.focusWindow])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let handshake = try await PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
            .handshake(client: PeekabooBridgeClientIdentity(
                bundleIdentifier: "dev.peekaboo.focus-dependency-tests",
                teamIdentifier: nil,
                processIdentifier: getpid()))

        #expect(!handshake.supportedOperations.contains(.focusWindow))
        #expect(handshake.enabledOperations?.contains(.focusWindow) == false)
        await host.stop()
    }

    @Test
    func `protocol 1 29 focus preserves structured post dispatch failure`() async throws {
        let socketPath = "/tmp/peekaboo-remote-window-focus-failure-\(UUID().uuidString).sock"
        let focusFailure = DesktopActionFailure.indeterminate(
            route: .local,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Focus completion is uncertain",
            hint: "Observe the intended window before retrying.")
        let windows = RemoteWindowMutationFixture(
            identity: self.identity,
            focusFailure: focusFailure)
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.listWindows, .focusWindow],
            windowOwnerProcessIdentifierProvider: { _ in 420 },
            windowBoundsProvider: { _ in CGRect(x: 0, y: 0, width: 100, height: 100) },
            processStartIdentityProvider: { _ in 9001 })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        do {
            try await client.focusWindow(target: .windowId(self.identity.windowID))
            Issue.record("Expected focus failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.mutationDispatched)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        let receipt = try #require(await client.lastOperationReceipt())
        #expect(receipt.payload.outcome?.state == .indeterminate)
        #expect(receipt.payload.outcome?.retrySafe == false)
        #expect(receipt.payload.target == .window(self.identity))
        await host.stop()
    }

    @Test
    func `queued legacy overload rejects a recycled process generation before dispatch`() async throws {
        let socketPath = "/tmp/peekaboo-remote-window-reuse-\(UUID().uuidString).sock"
        let identityState = RemoteWindowIdentityState(ownerPID: 420, processStartIdentity: 9001)
        let windows = RemoteWindowMutationFixture(identity: self.identity, blocksFirstLegacyMove: true)
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: Self.allowedOperations,
            windowOwnerProcessIdentifierProvider: { _ in identityState.ownerPID },
            windowBoundsProvider: { _ in CGRect(x: 0, y: 0, width: 100, height: 100) },
            processStartIdentityProvider: { _ in identityState.processStartIdentity })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let rawClient = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        let blockingMutation = Task {
            try await rawClient.sendExpectOK(.moveWindow(.init(
                target: .windowId(77),
                expectedIdentity: self.identity,
                position: CGPoint(x: 1, y: 1))))
        }
        await windows.waitUntilLegacyMutationStarted()

        let remote = RemoteWindowManagementService(
            client: PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2),
            supportsPinnedWindowMutations: true)
        let queuedMutation = Task {
            try await remote.resizeWindow(
                target: .title("Fixture"),
                to: CGSize(width: 200, height: 100))
        }
        // The unresolved list read is globally exclusive, so it must queue behind the active
        // exact-window mutation instead of observing a partially completed operation.
        try await Self.waitForConnectionCount(2, host: host)

        identityState.processStartIdentity = 9002
        await windows.releaseLegacyMutation()
        try await blockingMutation.value

        do {
            try await queuedMutation.value
            Issue.record("Expected the queued mutation to reject the recycled process generation")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .invalidRequest)
        }
        #expect(await windows.listCount == 1)
        #expect(await !((windows.pinnedMutations).contains { $0.operation == "resize" }))
        await host.stop()
    }

    private static let allowedOperations: Set<PeekabooBridgeOperation> = [
        .listWindows,
        .focusWindow,
        .moveWindow,
        .resizeWindow,
        .setWindowBounds,
        .closeWindow,
        .backgroundCloseWindow,
        .minimizeWindow,
        .restoreWindow,
        .maximizeWindow,
    ]

    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.window-outcome-tests",
        teamIdentifier: nil,
        processIdentifier: getpid(),
        hostname: nil)

    private static func waitForConnectionCount(
        _ expectedCount: Int,
        host: PeekabooBridgeHost) async throws
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await host.activeConnectionCountForTesting() != expectedCount {
            guard clock.now < deadline else { throw RemoteWindowTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum RemoteWindowTestError: Error {
    case timedOut
}

private struct RecordedRemoteWindowMutation: Equatable {
    let operation: String
    let target: String
    let identity: WindowMutationIdentity
}

private actor RemoteWindowMutationFixture: WindowManagementActionResultProviding {
    let identity: WindowMutationIdentity
    private var actionOutcome: DesktopActionOutcome?
    private let focusFailure: DesktopActionFailure?
    private let blocksFirstLegacyMove: Bool
    private var didBlockLegacyMove = false
    private var legacyMutationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var listCount = 0
    private(set) var legacyMutations: [String] = []
    private(set) var pinnedMutations: [RecordedRemoteWindowMutation] = []
    private(set) var focusedTargets: [String] = []

    init(
        identity: WindowMutationIdentity,
        blocksFirstLegacyMove: Bool = false,
        actionOutcome: DesktopActionOutcome? = nil,
        focusFailure: DesktopActionFailure? = nil)
    {
        self.identity = identity
        self.blocksFirstLegacyMove = blocksFirstLegacyMove
        self.actionOutcome = actionOutcome
        self.focusFailure = focusFailure
    }

    func setActionOutcome(_ outcome: DesktopActionOutcome?) {
        self.actionOutcome = outcome
    }

    func closeWindow(target: WindowTarget) async throws {
        self.legacyMutations.append("close:\(target)")
    }

    func closeWindow(target: WindowTarget, allowForegroundFallback: Bool) async throws {
        self.legacyMutations.append("close:\(allowForegroundFallback):\(target)")
    }

    func closeWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws
    {
        self.record(
            allowForegroundFallback ? "close" : "background-close",
            target: target,
            identity: expectedIdentity)
    }

    func closeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws -> DesktopActionResult<Void>
    {
        self.record(
            allowForegroundFallback ? "close" : "background-close",
            target: target,
            identity: expectedIdentity)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func minimizeWindow(target: WindowTarget) async throws {
        self.legacyMutations.append("minimize:\(target)")
    }

    func minimizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        self.record("minimize", target: target, identity: expectedIdentity)
    }

    func minimizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        self.record("minimize", target: target, identity: expectedIdentity)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func restoreWindow(target: WindowTarget) async throws {
        self.legacyMutations.append("restore:\(target)")
    }

    func restoreWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        self.record("restore", target: target, identity: expectedIdentity)
    }

    func restoreWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        self.record("restore", target: target, identity: expectedIdentity)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func maximizeWindow(target: WindowTarget) async throws {
        self.legacyMutations.append("maximize:\(target)")
    }

    func maximizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        self.record("maximize", target: target, identity: expectedIdentity)
    }

    func maximizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        self.record("maximize", target: target, identity: expectedIdentity)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func moveWindow(target: WindowTarget, to _: CGPoint) async throws {
        self.legacyMutations.append("move:\(target)")
        guard self.blocksFirstLegacyMove, !self.didBlockLegacyMove else { return }
        self.didBlockLegacyMove = true
        self.legacyMutationStarted = true
        self.startWaiters.forEach { $0.resume() }
        self.startWaiters.removeAll()
        await withCheckedContinuation { self.releaseContinuation = $0 }
    }

    func moveWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to _: CGPoint) async throws
    {
        self.record("move", target: target, identity: expectedIdentity)
        guard self.blocksFirstLegacyMove, !self.didBlockLegacyMove else { return }
        self.didBlockLegacyMove = true
        self.legacyMutationStarted = true
        self.startWaiters.forEach { $0.resume() }
        self.startWaiters.removeAll()
        await withCheckedContinuation { self.releaseContinuation = $0 }
    }

    func moveWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint) async throws -> DesktopActionResult<Void>
    {
        try await self.moveWindow(target: target, expectedIdentity: expectedIdentity, to: position)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func resizeWindow(target: WindowTarget, to _: CGSize) async throws {
        self.legacyMutations.append("resize:\(target)")
    }

    func resizeWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to _: CGSize) async throws
    {
        self.record("resize", target: target, identity: expectedIdentity)
    }

    func resizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to _: CGSize) async throws -> DesktopActionResult<Void>
    {
        self.record("resize", target: target, identity: expectedIdentity)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func setWindowBounds(target: WindowTarget, bounds _: CGRect) async throws {
        self.legacyMutations.append("set-bounds:\(target)")
    }

    func setWindowBounds(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds _: CGRect) async throws
    {
        self.record("set-bounds", target: target, identity: expectedIdentity)
    }

    func setWindowBoundsActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds _: CGRect) async throws -> DesktopActionResult<Void>
    {
        self.record("set-bounds", target: target, identity: expectedIdentity)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func focusWindow(target: WindowTarget) async throws {
        self.focusedTargets.append(target.description)
        if let focusFailure {
            throw focusFailure
        }
    }

    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        self.listCount += 1
        return [ServiceWindowInfo(
            windowID: self.identity.windowID,
            title: "Fixture",
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            mutationIdentity: self.identity)]
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }

    func waitUntilLegacyMutationStarted() async {
        guard !self.legacyMutationStarted else { return }
        await withCheckedContinuation { self.startWaiters.append($0) }
    }

    func releaseLegacyMutation() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }

    private func record(
        _ operation: String,
        target: WindowTarget,
        identity: WindowMutationIdentity)
    {
        self.pinnedMutations.append(RecordedRemoteWindowMutation(
            operation: operation,
            target: target.description,
            identity: identity))
    }
}

private final class RemoteWindowIdentityState: @unchecked Sendable {
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
