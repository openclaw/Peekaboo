import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge

struct PeekabooBridgeOperationScopeTests {
    private let process = ApplicationProcessIdentity(processIdentifier: 401, processStartIdentity: 9001)

    @Test
    func `Exact keyboard requests publish their application process scope`() {
        let identity = self.window(windowID: 71)
        let request = PeekabooBridgeRequest.exactWindowTargetedHotkey(.init(
            keys: "cmd,a",
            holdDuration: 10,
            expectedWindowIdentity: identity,
            expectedWindowBounds: CGRect(x: 1, y: 2, width: 300, height: 200)))

        #expect(request.desktopOperationScope == .process(self.process))
        #expect(request.nativeLeafOwnsDesktopOperationLane)
    }

    @Test
    func `Exact window geometry publishes a normalized window scope`() {
        let identity = self.window(windowID: 72)
        let request = PeekabooBridgeRequest.moveWindow(.init(
            target: .windowId(72),
            expectedIdentity: identity,
            position: CGPoint(x: 20, y: 30)))

        #expect(request.desktopOperationScope == .window(identity))
    }

    @Test
    func `PID-only and foreground requests remain globally conservative`() {
        let misleadingIdentity = self.window(windowID: 70)
        let targeted = PeekabooBridgeRequest.targetedHotkey(.init(
            keys: "cmd,a",
            holdDuration: 10,
            targetProcessIdentifier: self.process.processIdentifier))
        let foregroundClose = PeekabooBridgeRequest.closeWindow(.init(
            target: .windowId(72),
            expectedIdentity: self.window(windowID: 72)))
        let inconsistentClick = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: self.process.processIdentifier,
            targetWindowID: nil,
            expectedWindowIdentity: misleadingIdentity,
            expectedWindowBounds: misleadingIdentity.capturedBounds))

        #expect(targeted.desktopOperationScope == .global)
        #expect(foregroundClose.desktopOperationScope == .global)
        #expect(inconsistentClick.desktopOperationScope == .global)
    }

    @Test
    func `Background close and quit preserve generation-pinned scope`() {
        let identity = self.window(windowID: 73)
        let close = PeekabooBridgeRequest.backgroundCloseWindow(.init(
            target: .windowId(73),
            expectedIdentity: identity))
        let quit = PeekabooBridgeRequest.quitApplication(.init(
            identifier: "PID:\(self.process.processIdentifier)",
            force: false,
            expectedIdentity: self.process))

        #expect(close.desktopOperationScope == .window(identity))
        #expect(quit.desktopOperationScope == .process(self.process))
    }

    @Test
    func `Exact reads share their window lane while unresolved reads are globally exclusive`() {
        let identity = self.window(windowID: 74)
        let exact = PeekabooBridgeRequest.inspectAccessibilityTree(.init(windowContext: WindowContext(
            applicationProcessId: self.process.processIdentifier,
            windowID: identity.windowID,
            windowBounds: identity.capturedBounds,
            windowMutationIdentity: identity)))
        let publishingDetection = PeekabooBridgeRequest.detectElements(.init(
            imageData: Data(),
            snapshotId: "snapshot",
            windowContext: WindowContext(
                applicationProcessId: self.process.processIdentifier,
                windowID: identity.windowID,
                windowBounds: identity.capturedBounds,
                windowMutationIdentity: identity)))
        let unresolved = PeekabooBridgeRequest.captureScreen(.init(
            displayIndex: nil,
            visualizerMode: .none,
            scale: .logical1x))
        let mismatchedWindow = PeekabooBridgeRequest.inspectAccessibilityTree(.init(windowContext: WindowContext(
            applicationProcessId: self.process.processIdentifier,
            windowID: identity.windowID + 1,
            windowBounds: identity.capturedBounds,
            windowMutationIdentity: identity)))
        let mismatchedProcess = PeekabooBridgeRequest.inspectAccessibilityTree(.init(windowContext: WindowContext(
            applicationProcessId: self.process.processIdentifier + 1,
            windowID: identity.windowID,
            windowBounds: identity.capturedBounds,
            windowMutationIdentity: identity)))

        #expect(exact.desktopReadOperationLane?.scope == .window(identity))
        #expect(exact.desktopReadOperationLane?.access == .read)
        #expect(publishingDetection.desktopReadOperationLane?.scope == .global)
        #expect(publishingDetection.desktopReadOperationLane?.access == .write)
        #expect(unresolved.desktopReadOperationLane?.scope == .global)
        #expect(unresolved.desktopReadOperationLane?.access == .write)
        #expect(mismatchedWindow.desktopReadOperationLane?.scope == .global)
        #expect(mismatchedWindow.desktopReadOperationLane?.access == .write)
        #expect(mismatchedProcess.desktopReadOperationLane?.scope == .global)
        #expect(mismatchedProcess.desktopReadOperationLane?.access == .write)
    }

    @Test
    @MainActor
    func `Exact read narrowing rejects recycled process generations before dispatch`() throws {
        let identity = self.window(windowID: 75)
        let request = PeekabooBridgeRequest.inspectAccessibilityTree(.init(windowContext: WindowContext(
            applicationProcessId: self.process.processIdentifier,
            windowID: identity.windowID,
            windowBounds: identity.capturedBounds,
            windowMutationIdentity: identity)))
        let proposed = try #require(request.desktopReadOperationLane)
        let currentOwner: @Sendable (CGWindowID) -> pid_t? = { _ in self.process.processIdentifier }

        let currentServer = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            windowOwnerProcessIdentifierProvider: currentOwner,
            processStartIdentityProvider: { _ in self.process.processStartIdentity })
        let current = currentServer.validatedDesktopReadOperationLane(for: request, proposed: proposed)
        #expect(current.scope == DesktopOperationScope.window(identity))
        #expect(current.access == DesktopOperationAccess.read)

        let recycledServer = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            windowOwnerProcessIdentifierProvider: currentOwner,
            processStartIdentityProvider: { _ in self.process.processStartIdentity + 1 })
        let recycled = recycledServer.validatedDesktopReadOperationLane(for: request, proposed: proposed)
        #expect(recycled.scope == DesktopOperationScope.global)
        #expect(recycled.access == DesktopOperationAccess.write)
    }

    @Test
    @MainActor
    func `Exact read discards a result when the process generation changes during dispatch`() async throws {
        let identity = self.window(windowID: 76)
        let request = PeekabooBridgeRequest.inspectAccessibilityTree(.init(windowContext: WindowContext(
            applicationProcessId: self.process.processIdentifier,
            windowID: identity.windowID,
            windowBounds: identity.capturedBounds,
            windowMutationIdentity: identity)))
        let proposed = try #require(request.desktopReadOperationLane)
        let state = ExactReadGenerationState(self.process.processStartIdentity)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-exact-read-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            windowOwnerProcessIdentifierProvider: { _ in identity.ownerProcessIdentifier },
            processStartIdentityProvider: { _ in state.value })
        var dispatchCount = 0

        let result = try await server.withValidatedDesktopReadOperationLane(
            for: request,
            proposed: proposed)
        {
            dispatchCount += 1
            if dispatchCount == 1 {
                state.value = identity.ownerProcessStartIdentity + 1
            }
            return dispatchCount
        }

        #expect(result == 2)
        #expect(dispatchCount == 2)
    }

    private func window(windowID: Int) -> WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: self.process.processIdentifier,
            ownerProcessStartIdentity: self.process.processStartIdentity,
            capturedBounds: CGRect(x: 1, y: 2, width: 300, height: 200),
            isMinimized: false)
    }
}

private final class ExactReadGenerationState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UInt64

    init(_ value: UInt64) {
        self.storedValue = value
    }

    var value: UInt64 {
        get { self.lock.withLock { self.storedValue } }
        set { self.lock.withLock { self.storedValue = newValue } }
    }
}
