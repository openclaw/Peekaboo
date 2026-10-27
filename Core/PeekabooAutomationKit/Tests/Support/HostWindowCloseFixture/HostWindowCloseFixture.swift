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
        let diagnostics = SelectorFixtureDiagnostics(arguments: arguments)
        diagnostics?.record("entry", code: arguments.count, flags: [
            "--selector-launch", "--selector-payload", "--selector-plain",
        ].firstIndex(of: arguments.dropFirst().first ?? "").map { $0 + 1 } ?? 0)
        guard arguments.count == 4,
              ["--selector-launch", "--selector-payload", "--selector-plain"].contains(arguments[1]),
              UUID(uuidString: arguments[2]) != nil,
              arguments[3].hasPrefix("/")
        else {
            diagnostics?.record("arguments-invalid")
            exit(2)
        }
        if arguments[1] == "--selector-launch" {
            // LaunchServices registers Launcher before SETEXEC replaces it with Payload. The
            // parent must observe AppKit's real -1 state; re-exec alone is never a passing proof.
            let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/Payload").path
            let pointers = [executable, "--selector-payload", arguments[2], arguments[3]].map { strdup($0) }
            defer { pointers.forEach { free($0) } }
            var argv = pointers + [nil]
            var attributes: posix_spawnattr_t?
            let initialized = posix_spawnattr_init(&attributes)
            guard initialized == 0 else {
                diagnostics?.record("spawnattr-init", code: Int(initialized))
                exit(1)
            }
            defer { posix_spawnattr_destroy(&attributes) }
            let flags = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC))
            guard flags == 0 else {
                diagnostics?.record("spawnattr-flags", code: Int(flags))
                exit(1)
            }
            var processIdentifier: pid_t = 0
            // Bits report executable availability and Bundle agreement, without publishing either path.
            let spawnFlags = (FileManager.default.isExecutableFile(atPath: executable) ? 1 : 0) |
                (Bundle.main.bundleURL.resolvingSymlinksInPath() == diagnostics?.bundleURL ? 2 : 0)
            diagnostics?.record("spawn", flags: spawnFlags)
            let result = executable.withCString {
                posix_spawn(&processIdentifier, $0, nil, &attributes, &argv, environ)
            }
            diagnostics?.record("spawn-return", code: Int(result), flags: spawnFlags)
            exit(1) // A successful SETEXEC never returns.
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { exit(124) }
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let generation = SystemIdentityResolver.processStartIdentity(pid) else {
            diagnostics?.record("generation-missing")
            exit(1)
        }
        let receipt = SelectorFixtureReceipt(nonce: arguments[2], pid: pid, generation: generation)
        do {
            let output = URL(fileURLWithPath: arguments[3])
            let parentMatches = output.deletingLastPathComponent() == Bundle.main.bundleURL.deletingLastPathComponent()
            let nameMatches = output.lastPathComponent == "\(arguments[2]).json"
            diagnostics?.record("receipt-validation", flags: (parentMatches ? 1 : 0) | (nameMatches ? 2 : 0))
            guard parentMatches, nameMatches else { exit(2) }
            // Publish the whole ownership receipt before the parent can read it.
            try JSONEncoder().encode(receipt).write(to: output, options: .atomic)
            diagnostics?.record("receipt-published")
        } catch {
            let failure = error as NSError
            diagnostics?.record("receipt-write", code: failure.code, domain: failure.domain)
            exit(1)
        }
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

/// Diagnostic bytes never attest process ownership or authorize parent cleanup.
private final class SelectorFixtureDiagnostics {
    private(set) var bundleURL: URL?
    private let descriptor: Int32
    private var pathFlags = 0

    init?(arguments: [String]) {
        guard arguments.count == 4, UUID(uuidString: arguments[2]) != nil, arguments[3].hasPrefix("/")
        else { return nil }
        let output = URL(fileURLWithPath: arguments[3])
        let requestedRoot = output.deletingLastPathComponent()
        let temporaryParent = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath()
        // Admit only the existing private diagnostic file. Kernel and Bundle observations below
        // must not prevent recording entry, and this file never grants process ownership.
        guard output.lastPathComponent == "\(arguments[2]).json",
              requestedRoot.lastPathComponent.hasPrefix("pb-native-selector-"),
              requestedRoot.deletingLastPathComponent().resolvingSymlinksInPath() == temporaryParent
        else { return nil }
        // Resolve the temporary parent only; O_NOFOLLOW must still reject a symlink at the root itself.
        let root = temporaryParent.appendingPathComponent(requestedRoot.lastPathComponent, isDirectory: true)
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return nil }
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { return nil }
        let descriptor = openat(parent, "\(arguments[2]).status", O_WRONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
              info.st_size >= 0, info.st_size < 512
        else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
        self.record("child-admitted")

        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        guard count > 0 else {
            self.record("kernel-observation", code: Int(errno))
            return
        }
        self.pathFlags |= 1
        guard let path = String(
            bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
        else {
            self.record("kernel-observation", code: Int(count))
            return
        }
        self.pathFlags |= 2
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let directory = executable.deletingLastPathComponent()
        let contents = directory.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        self.bundleURL = bundle
        if ["Launcher", "Payload"].contains(executable.lastPathComponent),
           directory.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
           ["Unresolved.app", "Readable.app"].contains(bundle.lastPathComponent)
        {
            self.pathFlags |= 4
        }
        if bundle.deletingLastPathComponent() == root {
            self.pathFlags |= 8
        }
        if Bundle.main.bundleURL.resolvingSymlinksInPath() == bundle {
            self.pathFlags |= 16
        }
        self.record("kernel-observation", code: Int(count))
    }

    deinit { close(self.descriptor) }

    func record(_ stage: String, code: Int = 0, flags: Int = 0, domain: String = "none") {
        let domains = [
            "none",
            "NSCocoaErrorDomain",
            "NSPOSIXErrorDomain",
            "NSOSStatusErrorDomain",
            "NSMachErrorDomain",
            "NSWorkspaceErrorDomain",
            "RBSRequestErrorDomain",
            "RBSServiceErrorDomain",
        ]
        let boundedDomain = domains.contains(domain) ? domain : "other"
        // Low two bits describe the stage; higher bits retain query/UTF8/layout/root/Bundle agreement.
        let bytes = Array("\(stage)|\(code)|\(flags | (self.pathFlags << 2))|\(boundedDomain)".utf8)
        guard bytes.count < 512, ftruncate(self.descriptor, 0) == 0,
              lseek(self.descriptor, 0, SEEK_SET) == 0 else { return }
        _ = bytes.withUnsafeBytes { write(self.descriptor, $0.baseAddress, $0.count) }
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
