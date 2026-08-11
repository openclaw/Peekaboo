import AppKit
import Testing
@testable import Peekaboo

@Suite(.tags(.unit, .fast))
struct PeekabooAppLaunchPolicyTests {
    @Test
    func `ordinary launch remains interactive`() {
        let policy = PeekabooAppLaunchPolicy(arguments: ["Peekaboo"])

        #expect(policy.mode == .interactive)
        #expect(policy.allowsPresentation(.automatic))
        #expect(policy.allowsPresentation(.reopen))
        #expect(policy.allowsPresentation(.explicitUser))
        #expect(policy.allowsAPIKeyNudge)
        #expect(policy.allowsPermissionsOnboarding)
        #expect(!policy.suppressesAutomaticScenePresentation)
        #expect(!policy.disablesSceneRestoration)
        #expect(policy.initialActivationPolicy == nil)
        #expect(policy.allowsUpdaterStartup)
        #expect(policy.maximumBridgeOwnershipRetries == nil)
        #expect(!policy.terminatesOnPermanentBridgeFailure)
    }

    @Test
    func `background Bridge host launch is unattended and fail closed`() {
        let policy = PeekabooAppLaunchPolicy(arguments: [
            "/Applications/Peekaboo.app/Contents/MacOS/Peekaboo",
            PeekabooAppLaunchPolicy.backgroundBridgeHostArgument,
        ])

        #expect(policy.mode == .backgroundBridgeHost)
        #expect(!policy.allowsPresentation(.automatic))
        #expect(!policy.allowsPresentation(.reopen))
        #expect(policy.allowsPresentation(.explicitUser))
        #expect(!policy.allowsAPIKeyNudge)
        #expect(!policy.allowsPermissionsOnboarding)
        #expect(policy.suppressesAutomaticScenePresentation)
        #expect(policy.disablesSceneRestoration)
        #expect(policy.initialActivationPolicy == .accessory)
        #expect(!policy.allowsUpdaterStartup)
        #expect(policy.maximumBridgeOwnershipRetries == 6)
        #expect(policy.terminatesOnPermanentBridgeFailure)
    }

    @Test
    func `background Bridge host argument must be exact`() {
        let policy = PeekabooAppLaunchPolicy(arguments: [
            "Peekaboo",
            "--background-bridge-host=true",
        ])

        #expect(policy.mode == .interactive)
    }

    @Test
    @MainActor
    func `hidden settings helper is suppressed synchronously when attached`() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let contentView = HiddenWindowContentView(frame: window.contentView?.bounds ?? .zero)

        window.contentView = contentView

        #expect(window.identifier?.rawValue == "hidden-settings-helper")
        #expect(window.title.isEmpty)
        #expect(window.isExcludedFromWindowsMenu)
        #expect(window.alphaValue == 0)
        #expect(window.ignoresMouseEvents)
        #expect(window.collectionBehavior.contains(.transient))
        #expect(!window.isVisible)
    }

    @Test
    @MainActor
    func `background Bridge host never starts the updater`() {
        let policy = PeekabooAppLaunchPolicy(arguments: [
            "Peekaboo",
            PeekabooAppLaunchPolicy.backgroundBridgeHostArgument,
        ])

        let updater = makeUpdaterController(launchPolicy: policy)

        #expect(!updater.isAvailable)
        #expect(!updater.automaticallyChecksForUpdates)
    }
}
