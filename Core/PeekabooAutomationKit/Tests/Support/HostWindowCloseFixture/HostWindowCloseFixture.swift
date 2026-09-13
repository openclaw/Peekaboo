import AppKit
import Darwin
import PeekabooAutomationKit

@main
private enum HostWindowCloseFixture {
    @MainActor
    static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            FileHandle.standardError.write(Data("Host window close fixture timed out.\n".utf8))
            exit(124)
        }

        let application = NSApplication.shared
        let delegate = FixtureApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
        FileHandle.standardError.write(Data("AppKit run loop returned before fixture completion.\n".utf8))
        exit(1)
    }
}

@MainActor
private final class FixtureApplicationDelegate: NSObject, NSApplicationDelegate {
    private var targetWindow: NSWindow?

    func applicationDidFinishLaunching(_: Notification) {
        Task { @MainActor in
            do {
                try await self.closeHostWindow()
                FileHandle.standardOutput.write(Data("HOST_WINDOW_CLOSE_FIXTURE_COMPLETED\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Host window close fixture failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    private func closeHostWindow() async throws {
        let service = WindowManagementService()
        self.targetWindow = self.makeWindow(title: "Close target", origin: CGPoint(x: 100, y: 100))
        let sibling = self.makeWindow(title: "Keep open", origin: CGPoint(x: 500, y: 100))
        let targetDelegate = CloseDelegate()
        let siblingDelegate = CloseDelegate()
        targetDelegate.onClosed = { [weak self] in self?.targetWindow = nil }
        self.targetWindow?.delegate = targetDelegate
        sibling.delegate = siblingDelegate
        defer {
            self.targetWindow?.delegate = nil
            self.targetWindow?.close()
            self.targetWindow = nil
            sibling.delegate = nil
            sibling.close()
        }

        let identity = try await self.captureWindowIdentity(self.targetWindow)
        let siblingIdentity = try await self.captureWindowIdentity(sibling)

        do {
            let result = try await service.closeWindowActionResult(
                target: .windowId(identity.windowID),
                expectedIdentity: identity,
                allowForegroundFallback: false)
            guard result.outcome?.state == .confirmedChange,
                  result.outcome?.delivery == .init(mechanism: .accessibilityAction, mode: .background)
            else {
                throw FixtureFailure(
                    "Close did not report a confirmed background AX action: \(String(describing: result.outcome))")
            }
        } catch {
            let current = SystemIdentityResolver.windowIdentity(CGWindowID(identity.windowID))
            throw FixtureFailure(
                "\(error); receipt=\(identity); current=\(String(describing: current)); " +
                    "retained=\(self.targetWindow != nil); closes=\(targetDelegate.closeCount)")
        }
        guard targetDelegate.closeCount == 1,
              self.targetWindow == nil,
              SystemIdentityResolver.windowIdentity(CGWindowID(identity.windowID)) == nil
        else {
            throw FixtureFailure("Target did not disappear after its owner released the closed window")
        }
        guard siblingDelegate.closeCount == 0,
              sibling.isVisible,
              SystemIdentityResolver.validateWindowMutationIdentity(siblingIdentity)
        else {
            throw FixtureFailure("Closing the target changed its sibling")
        }
    }

    private func captureWindowIdentity(_ window: NSWindow?) async throws -> WindowMutationIdentity {
        // End this reference's lifetime before close so the delegate can release the WindowServer row.
        guard let window else { throw FixtureFailure("Fixture window is missing") }
        try await self.waitForWindowRegistration(window)
        guard let windowID = CGWindowID(exactly: window.windowNumber),
              let identity = SystemIdentityResolver.windowMutationIdentity(windowID: windowID),
              identity.ownerProcessIdentifier == ProcessInfo.processInfo.processIdentifier,
              window.isVisible
        else {
            throw FixtureFailure("Could not capture a visible host-owned window")
        }
        return identity
    }

    private func waitForWindowRegistration(_ window: NSWindow) async throws {
        guard let windowID = CGWindowID(exactly: window.windowNumber) else {
            throw FixtureFailure("Window has no WindowServer ID")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        // WindowServer initially publishes zero bounds even after orderFront returns.
        while ContinuousClock.now < deadline {
            if SystemIdentityResolver.windowIdentity(windowID)?.bounds.size == window.frame.size {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureFailure("WindowServer did not publish the fixture's window frame")
    }

    private func makeWindow(title: String, origin: CGPoint) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: origin, size: CGSize(width: 320, height: 240)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.orderFront(nil)
        return window
    }
}

@MainActor
private final class CloseDelegate: NSObject, NSWindowDelegate {
    private(set) var closeCount = 0
    var onClosed: (@MainActor () -> Void)?

    func windowWillClose(_: Notification) {
        MainActor.preconditionIsolated()
        self.closeCount += 1
        self.onClosed?()
    }
}

private struct FixtureFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
