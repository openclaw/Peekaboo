import CoreGraphics
import PeekabooAutomationKit
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeOperationScopeTests {
    private let process = ApplicationProcessIdentity(processIdentifier: 401, processStartIdentity: 9001)

    @Test
    func `Exact window requests publish a normalized window scope`() {
        let identity = self.window(windowID: 71)
        let request = PeekabooBridgeRequest.exactWindowTargetedHotkey(.init(
            keys: "cmd,a",
            holdDuration: 10,
            expectedWindowIdentity: identity,
            expectedWindowBounds: CGRect(x: 1, y: 2, width: 300, height: 200)))

        #expect(request.desktopOperationScope == .window(identity))
        #expect(request.nativeLeafOwnsDesktopOperationLane)
    }

    @Test
    func `PID-only and foreground requests remain globally conservative`() {
        let targeted = PeekabooBridgeRequest.targetedHotkey(.init(
            keys: "cmd,a",
            holdDuration: 10,
            targetProcessIdentifier: self.process.processIdentifier))
        let foregroundClose = PeekabooBridgeRequest.closeWindow(.init(
            target: .windowId(72),
            expectedIdentity: self.window(windowID: 72)))

        #expect(targeted.desktopOperationScope == .global)
        #expect(foregroundClose.desktopOperationScope == .global)
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

    private func window(windowID: Int) -> WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: self.process.processIdentifier,
            ownerProcessStartIdentity: self.process.processStartIdentity,
            capturedBounds: CGRect(x: 1, y: 2, width: 300, height: 200),
            isMinimized: false)
    }
}
