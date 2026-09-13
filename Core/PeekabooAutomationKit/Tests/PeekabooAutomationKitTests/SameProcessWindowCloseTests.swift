import AppKit
import PeekabooAutomationKit
import Testing

@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["RUN_AUTOMATION_ACTIONS"]?.lowercased() == "true"))
@MainActor
struct SameProcessWindowCloseTests {
    @Test
    func `background close keeps host callbacks on MainActor and preserves sibling windows`() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()

        let target = self.makeWindow(title: "Close target", origin: CGPoint(x: 100, y: 100))
        let sibling = self.makeWindow(title: "Keep open", origin: CGPoint(x: 500, y: 100))
        let targetDelegate = CloseDelegate()
        let siblingDelegate = CloseDelegate()
        target.delegate = targetDelegate
        sibling.delegate = siblingDelegate
        defer {
            target.delegate = nil
            sibling.delegate = nil
            target.close()
            sibling.close()
        }

        let targetWindowID = try #require(CGWindowID(exactly: target.windowNumber))
        let siblingWindowID = try #require(CGWindowID(exactly: sibling.windowNumber))
        try #require(target.isVisible && sibling.isVisible)
        let identity = try #require(SystemIdentityResolver.windowMutationIdentity(windowID: targetWindowID))
        let siblingIdentity = try #require(SystemIdentityResolver.windowMutationIdentity(windowID: siblingWindowID))
        #expect(identity.ownerProcessIdentifier == ProcessInfo.processInfo.processIdentifier)

        let result = try await WindowManagementService().closeWindowActionResult(
            target: .windowId(identity.windowID),
            expectedIdentity: identity,
            allowForegroundFallback: false)

        #expect(result.outcome?.state == .confirmedChange)
        #expect(result.outcome?.delivery == .init(mechanism: .accessibilityAction, mode: .background))
        #expect(targetDelegate.closeCount == 1)
        #expect(!target.isVisible)
        #expect(siblingDelegate.closeCount == 0)
        #expect(sibling.isVisible)
        #expect(SystemIdentityResolver.validateWindowMutationIdentity(siblingIdentity))
    }

    private func makeWindow(title: String, origin: CGPoint) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: origin, size: CGSize(width: 320, height: 240)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }
}

@MainActor
private final class CloseDelegate: NSObject, NSWindowDelegate {
    private(set) var closeCount = 0

    func windowWillClose(_: Notification) {
        MainActor.preconditionIsolated()
        self.closeCount += 1
    }
}
