import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge

@Suite(.serialized)
@MainActor
struct NativeWindowFocusProofTests {
    @Test
    func `production focus passes unchanged validation while geometry alone fails`() async throws {
        let windows = NativeFocusProofWindows()
        let geometry = try #require(windows.readback.catalog.serviceWindowInfo(windowID: 77))
        let result = try await windows.focusWindowProofActionResult(
            target: .windowId(77), expectedIdentity: windows.identity)
        let request = PeekabooBridgeRequest.focusWindow(.init(
            target: .windowId(77),
            expectedIdentity: windows.identity))
        #expect(geometry.isKeyWindow == nil)
        #expect(geometry.isFrontmost == nil)
        #expect(throws: (any Error).self) {
            try PeekabooBridgeOperationReceiptSemantics.validatePostMutationWindow(
                geometry, request: request, outcome: result.outcome)
        }
        try PeekabooBridgeOperationReceiptSemantics.validatePostMutationWindow(
            result.payload, request: request, outcome: result.outcome)
    }

    @Test(arguments: [false, true])
    func `signed remote focus uses production evidence and never geometry-only reread`(loseFocus: Bool) async throws {
        let windows = NativeFocusProofWindows()
        windows.focusedID = loseFocus ? 78 : 77
        let socketPath = "/tmp/peekaboo-native-focus-proof-\(UUID()).sock"
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows, ownedDesktopOperationLanes: [.focusWindow]),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.focusWindow],
            windowOwnerProcessIdentifierProvider: { _ in 420 },
            windowBoundsProvider: { _ in NativeFocusProofWindows.bounds },
            processStartIdentityProvider: { _ in 9001 })
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [], requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "boo.peekaboo.tests", teamIdentifier: nil, processIdentifier: getpid(), hostname: nil))
        do {
            let result = try await client.focusWindowResult(target: .windowId(77), expectedIdentity: windows.identity)
            #expect(!loseFocus)
            #expect(result.outcome?.isConfirmed == true)
            #expect(result.targetIdentity?.exactWindow?.identity.hasSameStableReceipt(as: windows.identity) == true)
        } catch let failure as DesktopActionFailure {
            #expect(loseFocus)
            #expect(failure.outcome.state == .indeterminate)
        }
        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.outcome?.retrySafe == false)
        #expect(bundle.receipt.payload.outcome?.dispatchState.mutationDispatched == true)
        #expect(bundle.receipt.payload.outcome?.dispatchState.unitCount == .one)
        #expect(bundle.receipt.payload.target == .window(windows.identity))
        if !loseFocus {
            let response = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self, from: bundle.canonicalResponse)
            guard case let .projectedAction(projected) = response, case let .window(window) = projected.response else {
                Issue.record("Missing signed focus readback")
                return
            }
            #expect(window?.isKeyWindow == true)
            #expect(window?.isFrontmost == true)
        }
        #expect(windows.dispatchCount == 1)
        #expect(windows.listCount == 0)
        await host.stop()
    }

    @Test
    func `older geometry-only provider still fails closed after accepted focus`() async throws {
        let windows = LegacyGeometryFocusWindows()
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows), allowlistedTeams: [], allowlistedBundles: [])
        let result = try await windows.focusWindowActionResult(
            target: .windowId(77),
            expectedIdentity: windows.identity)
        await #expect(throws: DesktopActionFailure.self) {
            try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                _ = try await server.windowMutationResponse(
                    request: .focusWindow(.init(target: .windowId(77), expectedIdentity: windows.identity)),
                    outcome: result.outcome)
            }
        }
        #expect(windows.dispatchCount == 1)
        #expect(windows.listCount == 1)
    }
}

@MainActor
private class LegacyGeometryFocusWindows: ScriptedWindowInventoryService,
WindowManagementPinnedFocusActionResultProviding {
    nonisolated static let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let identity = WindowMutationIdentity(
        windowID: 77, ownerProcessIdentifier: 420, ownerProcessStartIdentity: 9001, capturedBounds: bounds)
    var focusedID: CGWindowID? = 77
    var dispatchCount = 0
    var listCount = 0
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-focus-lane-\(UUID())")

    deinit { try? FileManager.default.removeItem(at: self.root) }

    var readback: WindowFocusReadback {
        let nativeIdentity: (CGWindowID) -> SystemWindowIdentity? = { id in
            SystemWindowIdentity(
                windowID: id,
                ownerProcessIdentifier: 420,
                title: "Fixture",
                bounds: Self.bounds,
                layer: 0,
                alpha: 1,
                isOnScreen: true,
                sharingState: .readOnly)
        }
        return WindowFocusReadback(
            catalog: WindowCGInfoLookup(
                windowListProvider: { _, _ in
                    [[
                        kCGWindowNumber as String: 77,
                        kCGWindowOwnerPID as String: 420,
                        kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 100, "Height": 100],
                        kCGWindowIsOnscreen as String: true,
                    ]]
                },
                processStartIdentityProvider: { _ in 9001 },
                currentWindowIdentityProvider: nativeIdentity,
                isMainWindowProvider: { _ in true }),
            processStartIdentity: { _ in 9001 },
            windowIdentity: nativeIdentity,
            focusedWindowID: { _, _ in self.focusedID },
            frontmostPID: { 420 })
    }

    override func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        self.listCount += 1
        return try [#require(self.readback.catalog.serviceWindowInfo(windowID: 77))]
    }

    func focusWindowActionResult(target: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        try await self.focusWindowActionResult(target: target, expectedIdentity: self.identity)
    }

    func focusWindowActionResult(
        target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<Void>
    {
        let result = try await self.nativeFocus(target: target, expectedIdentity: expectedIdentity)
        return UIAutomationActionResult(payload: (), outcome: result.outcome, targetIdentity: result.targetIdentity)
    }

    func nativeFocus(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<ServiceWindowInfo>
    {
        let readback = self.readback
        let service = WindowManagementService(
            operationLaneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: self.root))
        return try await service.focusWindowProofActionResult(
            target: target,
            expectedIdentity: expectedIdentity,
            validateBeforeDispatch: { try readback.validateIdentity(expectedIdentity) },
            dispatch: { options, record in
                #expect(options.retryCount == 1)
                self.dispatchCount += 1
                _ = try FocusDispatchAccounting.acceptingBool(
                    delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                    onDispatch: record,
                    operation: { true })
            },
            readback: readback)
    }
}

@MainActor
private final class NativeFocusProofWindows: LegacyGeometryFocusWindows, WindowManagementFocusProofProviding {
    func focusWindowProofActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<ServiceWindowInfo>
    {
        try await self.nativeFocus(target: target, expectedIdentity: expectedIdentity)
    }
}
