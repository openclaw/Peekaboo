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
    func `Generation-pinned process input publishes its application process scope`() {
        let hotkey = PeekabooBridgeRequest.targetedHotkey(.init(
            keys: "cmd,a",
            holdDuration: 10,
            targetProcessIdentifier: self.process.processIdentifier,
            expectedProcessIdentity: self.process))
        let type = PeekabooBridgeRequest.targetedTypeActions(.init(
            actions: [.text("hello")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            targetProcessIdentifier: self.process.processIdentifier,
            expectedProcessIdentity: self.process))
        let click = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: self.process.processIdentifier,
            expectedProcessIdentity: self.process))

        for request in [hotkey, type, click] {
            #expect(request.desktopOperationScope == .process(self.process))
            #expect(request.nativeLeafOwnsDesktopOperationLane)
        }
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
            windowBoundsProvider: { _ in identity.capturedBounds },
            processStartIdentityProvider: { _ in self.process.processStartIdentity })
        let current = currentServer.validatedDesktopReadOperationLane(for: request, proposed: proposed)
        #expect(current.scope == DesktopOperationScope.window(identity))
        #expect(current.access == DesktopOperationAccess.read)

        let recycledServer = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            windowOwnerProcessIdentifierProvider: currentOwner,
            windowBoundsProvider: { _ in identity.capturedBounds },
            processStartIdentityProvider: { _ in self.process.processStartIdentity + 1 })
        let recycled = recycledServer.validatedDesktopReadOperationLane(for: request, proposed: proposed)
        #expect(recycled.scope == DesktopOperationScope.global)
        #expect(recycled.access == DesktopOperationAccess.write)
    }

    @Test
    @MainActor
    func `Exact read fails closed without redispatch when the process generation changes`() async throws {
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
            windowBoundsProvider: { _ in identity.capturedBounds },
            processStartIdentityProvider: { _ in state.value })
        var dispatchCount = 0

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await server.withValidatedDesktopReadOperationLane(
                for: request,
                proposed: proposed)
            {
                dispatchCount += 1
                state.value = identity.ownerProcessStartIdentity + 1
                return dispatchCount
            }
        }

        #expect(dispatchCount == 1)
    }

    @Test
    @MainActor
    func `Exact live frames yield to a queued same process writer while other processes overlap`() async throws {
        let identity = self.window(windowID: 77)
        let request = PeekabooBridgeRequest.captureWindow(.init(
            appIdentifier: "",
            windowIndex: nil,
            windowId: identity.windowID,
            visualizerMode: .none,
            scale: .logical1x))
        let proposed = try #require(request.desktopReadOperationLane)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-live-frame-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let server = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            desktopOperationLaneCoordinator: coordinator,
            windowOwnerProcessIdentifierProvider: { _ in identity.ownerProcessIdentifier },
            windowBoundsProvider: { _ in identity.capturedBounds },
            processStartIdentityProvider: { pid in
                pid == identity.ownerProcessIdentifier ? identity.ownerProcessStartIdentity : 500
            })
        let firstFrameStarted = BridgeScopeLatch()
        let firstFrameRelease = BridgeScopeLatch()
        let writerStarted = BridgeScopeLatch()
        let writerRelease = BridgeScopeLatch()
        let secondFrameStarted = BridgeScopeLatch()
        let otherProcessStarted = BridgeScopeLatch()

        let firstFrame = Task {
            try await server.withValidatedDesktopReadOperationLane(for: request, proposed: proposed) {
                await firstFrameStarted.open()
                await firstFrameRelease.wait()
            }
        }
        await firstFrameStarted.wait()

        let otherProcess = ApplicationProcessIdentity(processIdentifier: 402, processStartIdentity: 500)
        let otherWriter = Task {
            try await coordinator.run(scope: .process(otherProcess), access: .write) {
                await otherProcessStarted.open()
            }
        }
        let otherProcessOverlapped = await otherProcessStarted.opensWithin(.seconds(1))
        #expect(otherProcessOverlapped)
        try await otherWriter.value

        let sameProcessWriter = Task {
            try await coordinator.run(scope: .process(self.process), access: .write) {
                await writerStarted.open()
                await writerRelease.wait()
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let secondFrame = Task {
            try await server.withValidatedDesktopReadOperationLane(for: request, proposed: proposed) {
                await secondFrameStarted.open()
            }
        }

        await firstFrameRelease.open()
        let writerWonTurnstile = await writerStarted.opensWithin(.seconds(1))
        let secondFrameOvertookWriter = await secondFrameStarted.opensWithin(.milliseconds(100))
        #expect(writerWonTurnstile)
        #expect(!secondFrameOvertookWriter)
        await writerRelease.open()

        try await firstFrame.value
        try await sameProcessWriter.value
        try await secondFrame.value
        let secondFrameEventuallyStarted = await secondFrameStarted.isOpen
        #expect(secondFrameEventuallyStarted)
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

private actor BridgeScopeLatch {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var isOpen: Bool {
        self.opened
    }

    func open() {
        guard !self.opened else { return }
        self.opened = true
        let pending = self.continuations
        self.continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !self.opened else { return }
        await withCheckedContinuation { self.continuations.append($0) }
    }

    func opensWithin(_ duration: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while !self.opened, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return self.opened
    }
}
