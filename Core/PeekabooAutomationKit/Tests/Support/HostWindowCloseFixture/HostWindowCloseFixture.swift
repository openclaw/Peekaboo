import AppKit
import Darwin
import Foundation
import PeekabooAutomationKit

@main
private enum HostWindowCloseFixture {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first?.hasPrefix("--selector-") == true {
            self.runSelectorFixture()
            return
        }
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

    @MainActor
    private static func runSelectorFixture() {
        let arguments = CommandLine.arguments
        guard arguments.count == 4,
              ["--selector-launch", "--selector-payload", "--selector-plain"].contains(arguments[1]),
              UUID(uuidString: arguments[2]) != nil,
              arguments[3].hasPrefix("/")
        else { exit(2) }
        if arguments[1] == "--selector-launch" {
            // LaunchServices registers Launcher before SETEXEC replaces it with Payload. The
            // parent must observe AppKit's real -1 state; re-exec alone is never a passing proof.
            let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/Payload").path
            let pointers = [executable, "--selector-payload", arguments[2], arguments[3]].map { strdup($0) }
            defer { pointers.forEach { free($0) } }
            var argv = pointers + [nil]
            var attributes: posix_spawnattr_t?
            guard posix_spawnattr_init(&attributes) == 0 else { exit(1) }
            defer { posix_spawnattr_destroy(&attributes) }
            guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC)) == 0 else { exit(1) }
            var processIdentifier: pid_t = 0
            _ = executable.withCString { posix_spawn(&processIdentifier, $0, nil, &attributes, &argv, environ) }
            exit(1) // A successful SETEXEC never returns.
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { exit(124) }
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let generation = SystemIdentityResolver.processStartIdentity(pid) else { exit(1) }
        let receipt = SelectorFixtureReceipt(nonce: arguments[2], pid: pid, generation: generation)
        do {
            let output = URL(fileURLWithPath: arguments[3])
            guard output.deletingLastPathComponent() == Bundle.main.bundleURL.deletingLastPathComponent(),
                  output.lastPathComponent == "\(arguments[2]).json"
            else { exit(2) }
            // Publish the whole ownership receipt before the parent can read it.
            try JSONEncoder().encode(receipt).write(to: output, options: .atomic)
        } catch { exit(1) }
        let application = NSApplication.shared
        let delegate = SelectorFixtureDelegate()
        let stopURL = URL(fileURLWithPath: arguments[3]).deletingPathExtension().appendingPathExtension("stop")
        let shutdown = DispatchSource.makeTimerSource(queue: .global())
        shutdown.schedule(deadline: .now(), repeating: .milliseconds(50))
        shutdown.setEventHandler {
            if (try? String(contentsOf: stopURL, encoding: .utf8)) == arguments[2] {
                exit(0)
            }
        }
        shutdown.resume()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime((delegate, shutdown)) { application.run() }
        exit(1)
    }
}

private struct SelectorFixtureReceipt: Encodable {
    let nonce: String
    let pid: pid_t
    let generation: UInt64
}

@MainActor
private final class SelectorFixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_: Notification) {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 160, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.title = "Selector fixture"
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.orderFront(nil)
        self.window = window
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
