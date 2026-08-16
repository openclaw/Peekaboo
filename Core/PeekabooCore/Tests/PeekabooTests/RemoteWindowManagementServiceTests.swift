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
        let legacyVersion = PeekabooBridgeConstants.desktopActionOutcomeProjectionVersion
        let closeExpected = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            unitCount: .one)
        let valueExpected = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            unitCount: .one)
        let windows = RemoteWindowMutationFixture(identity: self.identity, actionOutcome: closeExpected)
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

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity, protocolVersion: legacyVersion)
        let remote = RemoteWindowManagementService(
            client: client,
            supportsBackgroundClose: true,
            supportsPinnedWindowMutations: true,
            supportsWindowRestore: true)
        let target = WindowTarget.windowId(self.identity.windowID)
        let closeOutcomes = try await [
            remote.closeWindowResult(
                target: target,
                expectedIdentity: self.identity,
                allowForegroundFallback: false),
            remote.closeWindowResult(
                target: target,
                expectedIdentity: self.identity,
                allowForegroundFallback: true),
        ]
        #expect(closeOutcomes.allSatisfy { $0.outcome == closeExpected.routed(to: .bridge) })

        await windows.setActionOutcome(valueExpected)
        let valueOutcomes = try await [
            remote.minimizeWindowResult(target: target, expectedIdentity: self.identity),
            remote.restoreWindowResult(target: target, expectedIdentity: self.identity),
            remote.maximizeWindowResult(target: target, expectedIdentity: self.identity),
            remote.moveWindowResult(target: target, expectedIdentity: self.identity, to: .zero),
            remote.resizeWindowResult(target: target, expectedIdentity: self.identity, to: .zero),
            remote.setWindowBoundsResult(target: target, expectedIdentity: self.identity, bounds: .zero),
        ]

        #expect(valueOutcomes.allSatisfy { $0.outcome == valueExpected.routed(to: .bridge) })
        let compatibilityOutcome: DesktopActionOutcome? = try await remote.moveWindowWithOutcome(
            target: target,
            expectedIdentity: self.identity,
            to: .zero)
        #expect(compatibilityOutcome == valueExpected.routed(to: .bridge))
        let bridgeCompatibilityOutcome: DesktopActionOutcome? = try await client.moveWindowWithOutcome(
            target: target,
            expectedIdentity: self.identity,
            to: .zero)
        #expect(bridgeCompatibilityOutcome == valueExpected.routed(to: .bridge))
        let compatibleMoveOutcomes: [DesktopActionOutcome] = [
            valueExpected,
            .confirmedNoChange(),
            .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one),
            .suspectedNoop(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                unitCount: .one),
        ]
        for expectedOutcome in compatibleMoveOutcomes {
            await windows.setActionOutcome(expectedOutcome)
            let carried = try await remote.moveWindowResult(
                target: target,
                expectedIdentity: self.identity,
                to: CGPoint(x: 12, y: 34))
            #expect(carried.outcome == expectedOutcome.routed(to: .bridge))
        }
        await windows.setActionOutcome(nil)
        let missingOutcome = try await remote.moveWindowResult(
            target: target,
            expectedIdentity: self.identity,
            to: CGPoint(x: 56, y: 78))
        #expect(missingOutcome.outcome == nil)
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

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
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
        let legacyVersion = PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion
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

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity, protocolVersion: legacyVersion)
        let remote = RemoteWindowManagementService(
            client: client,
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
        let legacyVersion = PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion
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

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity, protocolVersion: legacyVersion)
        let remote = RemoteWindowManagementService(
            client: client,
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
        let legacyVersion = PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion
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

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity, protocolVersion: legacyVersion)
        let remote = RemoteWindowManagementService(
            client: client,
            supportsPinnedWindowMutations: false)
        let result = try await remote.listWindows(target: .title("Fixture"))
        try await remote.focusWindow(target: .windowId(77))

        #expect(result.map(\.windowID) == [77])
        #expect(await windows.focusedTargets == ["windowId(77)"])
        await host.stop()
    }

    @Test
    func `protocol 1 28 pinned focus refuses locally while explicit legacy focus still works`() async throws {
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

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(
            client: PeekabooBridgeClientIdentity(
                bundleIdentifier: "dev.peekaboo.focus-only-tests",
                teamIdentifier: nil,
                processIdentifier: getpid()))
        let remote = RemoteWindowManagementService(
            client: client,
            supportsPinnedWindowMutations: false)

        do {
            _ = try await remote.focusWindowActionResult(
                target: .windowId(77),
                expectedIdentity: self.identity)
            Issue.record("Expected pinned focus to reject a receiptless 1.28 session")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(await windows.listCount == 0)
        #expect(await windows.focusedTargets.isEmpty)

        let result = try await remote.focusWindowResult(target: .windowId(77))

        #expect(await windows.listCount == 0)
        #expect(await windows.focusedTargets == ["windowId(77)"])
        #expect(result.outcome == nil)
        #expect(result.targetIdentity == nil)
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

        let handshake = try await TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
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

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
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
    func `protocol 1 29 signs provider focus refusal without fabricated dispatch`() async throws {
        let socketPath = "/tmp/peekaboo-remote-window-focus-refusal-\(UUID().uuidString).sock"
        let windows = RemoteWindowMutationFixture(
            identity: self.identity,
            focusResultOutcome: .refused(reason: .targetUnavailable),
            omitsFocusTarget: true)
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

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        do {
            try await client.focusWindow(target: .windowId(self.identity.windowID))
            Issue.record("Expected provider focus refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        let receipt = try #require(await client.lastOperationReceipt())
        #expect(receipt.payload.outcome?.state == .refused)
        #expect(receipt.payload.outcome?.mutationDispatched == false)
        #expect(receipt.payload.outcome?.retrySafe == true)
        await host.stop()
    }

    @Test
    func `protocol 1 29 focus signs a dispatched outcome on success`() async throws {
        let socketPath = "/tmp/peekaboo-remote-window-focus-success-\(UUID().uuidString).sock"
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

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let remote: any WindowManagementServiceProtocol = RemoteWindowManagementService(
            client: client,
            supportsPinnedWindowMutations: true)
        let result = try await remote.focusWindowResult(target: .windowId(self.identity.windowID))

        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.route == .bridge)
        #expect(result.targetIdentity?.exactWindow?.identity == self.identity)
        let receipt = try #require(await client.lastOperationReceipt())
        #expect(receipt.payload.outcome?.state == .dispatchedUnverified)
        #expect(receipt.payload.outcome?.retrySafe == false)
        #expect(receipt.payload.outcome?.dispatchState.mutationDispatched == true)
        #expect(receipt.payload.target == .window(self.identity))
        await host.stop()
    }

    @Test
    func `protocol 1 29 confirmed mutations return signed postcondition proof`() async throws {
        let socketPath = "/tmp/peekaboo-confirmed-window-proof-\(UUID().uuidString).sock"
        let windows = RemoteWindowMutationFixture(
            identity: self.identity,
            tracksConfirmedState: true)
        let liveBounds = RemoteWindowBoundsState(
            self.identity.capturedBounds ?? CGRect(x: 0, y: 0, width: 100, height: 100))
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: Self.allowedOperations,
            windowOwnerProcessIdentifierProvider: { _ in 420 },
            windowBoundsProvider: { _ in liveBounds.value },
            processStartIdentityProvider: { _ in 9001 })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        var identity = self.identity

        func expectProof(_ expectedWindow: ServiceWindowInfo?) async throws {
            let bundle = try #require(await client.lastOperationReceiptBundle())
            try bundle.validate()
            let response = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self,
                from: bundle.canonicalResponse)
            guard case let .projectedAction(projected) = response,
                  case let .window(window) = projected.response
            else {
                Issue.record("Expected a signed postmutation window response")
                return
            }
            #expect(window == expectedWindow)
            #expect(projected.outcome?.outcome.isConfirmed == true)
        }

        let focus = try await client.focusWindowResult(
            target: .windowId(identity.windowID),
            expectedIdentity: identity)
        #expect(focus.outcome?.state == .confirmedChange)
        var readback = try await windows.listWindows(target: .windowId(identity.windowID)).first
        try await expectProof(readback)

        let movedOrigin = CGPoint(x: 40, y: 50)
        let moved = try await client.moveWindowResult(
            target: .windowId(identity.windowID),
            expectedIdentity: identity,
            to: movedOrigin)
        #expect(moved.outcome?.state == .confirmedChange)
        identity = WindowMutationIdentity(
            windowID: identity.windowID,
            ownerProcessIdentifier: identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: identity.ownerProcessStartIdentity,
            capturedBounds: CGRect(origin: movedOrigin, size: identity.capturedBounds?.size ?? .zero),
            isMinimized: false)
        liveBounds.value = try #require(identity.capturedBounds)
        readback = try await windows.listWindows(target: .windowId(identity.windowID)).first
        try await expectProof(readback)

        let resizedSize = CGSize(width: 320, height: 240)
        _ = try await client.resizeWindowResult(
            target: .windowId(identity.windowID),
            expectedIdentity: identity,
            to: resizedSize)
        identity = WindowMutationIdentity(
            windowID: identity.windowID,
            ownerProcessIdentifier: identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: identity.ownerProcessStartIdentity,
            capturedBounds: CGRect(origin: movedOrigin, size: resizedSize),
            isMinimized: false)
        liveBounds.value = try #require(identity.capturedBounds)
        readback = try await windows.listWindows(target: .windowId(identity.windowID)).first
        try await expectProof(readback)

        let requestedBounds = CGRect(x: 60, y: 70, width: 360, height: 260)
        _ = try await client.setWindowBoundsResult(
            target: .windowId(identity.windowID),
            expectedIdentity: identity,
            bounds: requestedBounds)
        identity = WindowMutationIdentity(
            windowID: identity.windowID,
            ownerProcessIdentifier: identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: identity.ownerProcessStartIdentity,
            capturedBounds: requestedBounds,
            isMinimized: false)
        liveBounds.value = requestedBounds
        readback = try await windows.listWindows(target: .windowId(identity.windowID)).first
        try await expectProof(readback)

        _ = try await client.minimizeWindowResult(
            target: .windowId(identity.windowID),
            expectedIdentity: identity)
        identity = identity.withMinimizedState(true)
        readback = try await windows.listWindows(target: .windowId(identity.windowID)).first
        try await expectProof(readback)

        _ = try await client.restoreWindowResult(
            target: .windowId(identity.windowID),
            expectedIdentity: identity)
        identity = identity.withMinimizedState(false)
        readback = try await windows.listWindows(target: .windowId(identity.windowID)).first
        try await expectProof(readback)

        _ = try await client.closeWindowResult(
            target: .windowId(identity.windowID),
            expectedIdentity: identity,
            allowForegroundFallback: false)
        try await expectProof(nil)
        await host.stop()
    }

    @Test
    func `protocol 1 29 focus cancellation remains retry unsafe`() async throws {
        let socketPath = "/tmp/peekaboo-remote-window-focus-cancel-\(UUID().uuidString).sock"
        let windows = RemoteWindowMutationFixture(
            identity: self.identity,
            cancelsFocus: true)
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

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        do {
            try await client.focusWindow(target: .windowId(self.identity.windowID))
            Issue.record("Expected focus cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        let receipt = try #require(await client.lastOperationReceipt())
        #expect(receipt.payload.outcome?.state == .indeterminate)
        #expect(receipt.payload.outcome?.retrySafe == false)
        await host.stop()
    }

    @Test
    func `queued legacy overload rejects a recycled process generation before dispatch`() async throws {
        let socketPath = "/tmp/peekaboo-remote-window-reuse-\(UUID().uuidString).sock"
        let legacyVersion = PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion
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

        let rawClient = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await rawClient.handshake(client: Self.clientIdentity, protocolVersion: legacyVersion)
        let overloadClient = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await overloadClient.handshake(client: Self.clientIdentity, protocolVersion: legacyVersion)
        let blockingMutation = Task {
            try await rawClient.sendExpectOK(.moveWindow(.init(
                target: .windowId(77),
                expectedIdentity: self.identity,
                position: CGPoint(x: 1, y: 1))))
        }
        await windows.waitUntilLegacyMutationStarted()

        let remote = RemoteWindowManagementService(
            client: overloadClient,
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
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.outcome.refusalReason == .invalidRequest)
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

private actor RemoteWindowMutationFixture: WindowManagementActionResultProviding,
    WindowManagementPinnedFocusActionResultProviding
{
    let identity: WindowMutationIdentity
    private var actionOutcome: DesktopActionOutcome?
    private let focusFailure: DesktopActionFailure?
    private let focusResultOutcome: DesktopActionOutcome?
    private let omitsFocusTarget: Bool
    private let cancelsFocus: Bool
    private let blocksFirstLegacyMove: Bool
    private let tracksConfirmedState: Bool
    private var currentBounds: CGRect
    private var currentMinimized: Bool
    private var currentIsKeyWindow = false
    private var isClosed = false
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
        focusFailure: DesktopActionFailure? = nil,
        focusResultOutcome: DesktopActionOutcome? = nil,
        omitsFocusTarget: Bool = false,
        cancelsFocus: Bool = false,
        tracksConfirmedState: Bool = false)
    {
        self.identity = identity
        self.blocksFirstLegacyMove = blocksFirstLegacyMove
        self.actionOutcome = actionOutcome
        self.focusFailure = focusFailure
        self.focusResultOutcome = focusResultOutcome
        self.omitsFocusTarget = omitsFocusTarget
        self.cancelsFocus = cancelsFocus
        self.tracksConfirmedState = tracksConfirmedState
        self.currentBounds = identity.capturedBounds ?? CGRect(x: 0, y: 0, width: 100, height: 100)
        self.currentMinimized = identity.isMinimized == true
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
        if self.tracksConfirmedState {
            self.isClosed = true
        }
        let trackedOutcome: DesktopActionOutcome? = self.tracksConfirmedState ? .confirmedChange(
            delivery: .init(
                mechanism: .accessibilityAction,
                mode: allowForegroundFallback ? .foreground : .background),
            unitCount: .one) : nil
        return DesktopActionResult(outcome: trackedOutcome ?? self.actionOutcome)
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
        if self.tracksConfirmedState {
            self.currentMinimized = true
        }
        return DesktopActionResult(outcome: self.trackedValueOutcome ?? self.actionOutcome)
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
        if self.tracksConfirmedState {
            self.currentMinimized = false
        }
        return DesktopActionResult(outcome: self.trackedValueOutcome ?? self.actionOutcome)
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
        to position: CGPoint) async throws
    {
        self.record("move", target: target, identity: expectedIdentity)
        if self.tracksConfirmedState {
            self.currentBounds.origin = position
        }
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
        return DesktopActionResult(outcome: self.trackedValueOutcome ?? self.actionOutcome)
    }

    func resizeWindow(target: WindowTarget, to _: CGSize) async throws {
        self.legacyMutations.append("resize:\(target)")
    }

    func resizeWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize) async throws
    {
        self.record("resize", target: target, identity: expectedIdentity)
        if self.tracksConfirmedState {
            self.currentBounds.size = size
        }
    }

    func resizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize) async throws -> DesktopActionResult<Void>
    {
        try await self.resizeWindow(target: target, expectedIdentity: expectedIdentity, to: size)
        return DesktopActionResult(outcome: self.trackedValueOutcome ?? self.actionOutcome)
    }

    func setWindowBounds(target: WindowTarget, bounds _: CGRect) async throws {
        self.legacyMutations.append("set-bounds:\(target)")
    }

    func setWindowBounds(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async throws
    {
        self.record("set-bounds", target: target, identity: expectedIdentity)
        if self.tracksConfirmedState {
            self.currentBounds = bounds
        }
    }

    func setWindowBoundsActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async throws -> DesktopActionResult<Void>
    {
        try await self.setWindowBounds(target: target, expectedIdentity: expectedIdentity, bounds: bounds)
        return DesktopActionResult(outcome: self.trackedValueOutcome ?? self.actionOutcome)
    }

    func focusWindow(target: WindowTarget) async throws {
        self.focusedTargets.append(target.description)
        if let focusFailure {
            throw focusFailure
        }
        if self.cancelsFocus {
            throw CancellationError()
        }
    }

    func focusWindowActionResult(target: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        try await self.focusWindowActionResult(target: target, expectedIdentity: self.identity)
    }

    func focusWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<Void>
    {
        guard expectedIdentity.hasSameStableReceipt(as: self.identity) else {
            throw PeekabooError.commandFailed("Bridge forwarded a different focus receipt")
        }
        try await self.focusWindow(target: target)
        if self.tracksConfirmedState {
            self.currentIsKeyWindow = true
        }
        let currentIdentity = self.currentIdentity
        let exactWindow = try UIAutomationTarget.ExactWindow(identity: currentIdentity, bounds: self.currentBounds)
        let trackedOutcome: DesktopActionOutcome? = self.tracksConfirmedState ? .confirmedChange(
            delivery: .init(mechanism: .composite, mode: .foreground),
            unitCount: DesktopActionOutcome.DispatchUnitCount(3)) : nil
        let outcome = self.focusResultOutcome ?? trackedOutcome ?? self.actionOutcome ?? .dispatchedUnverified(
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(3))
        return UIAutomationActionResult(
            payload: (),
            outcome: outcome,
            targetIdentity: self.omitsFocusTarget ? nil : DesktopTargetIdentity(exactWindow: exactWindow))
    }

    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        self.listCount += 1
        guard !self.isClosed else { return [] }
        return [ServiceWindowInfo(
            windowID: self.identity.windowID,
            title: "Fixture",
            bounds: self.currentBounds,
            isMinimized: self.currentMinimized,
            isKeyWindow: self.currentIsKeyWindow,
            mutationIdentity: self.currentIdentity)]
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

    private var trackedValueOutcome: DesktopActionOutcome? {
        self.tracksConfirmedState ? .confirmedChange(
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            unitCount: .one) : nil
    }

    private var currentIdentity: WindowMutationIdentity {
        guard self.tracksConfirmedState else { return self.identity }
        return WindowMutationIdentity(
            windowID: self.identity.windowID,
            ownerProcessIdentifier: self.identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: self.identity.ownerProcessStartIdentity,
            capturedBounds: self.currentBounds,
            isMinimized: self.currentMinimized)
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

private final class RemoteWindowBoundsState: @unchecked Sendable {
    private let lock = NSLock()
    private var bounds: CGRect

    init(_ bounds: CGRect) {
        self.bounds = bounds
    }

    var value: CGRect {
        get { self.lock.withLock { self.bounds } }
        set { self.lock.withLock { self.bounds = newValue } }
    }
}
