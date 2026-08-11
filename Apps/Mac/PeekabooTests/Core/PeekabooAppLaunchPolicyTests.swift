import AppKit
import PeekabooBridge
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
    func `matching managed build receipt restores background mode after login`() throws {
        let receipt = try #require(self.receipt(bundleVersion: "42", codeSignatureHash: "abc123"))

        let policy = PeekabooAppLaunchPolicy(
            arguments: ["Peekaboo"],
            managedReceipt: receipt,
            currentBuildReceipt: receipt)

        #expect(policy.mode == .backgroundBridgeHost)
    }

    @Test
    func `rolled back build ignores another generation receipt`() throws {
        let managed = try #require(self.receipt(bundleVersion: "42", codeSignatureHash: "abc123"))
        let restored = try #require(self.receipt(bundleVersion: "41", codeSignatureHash: "def456"))

        let policy = PeekabooAppLaunchPolicy(
            arguments: ["Peekaboo"],
            managedReceipt: managed,
            currentBuildReceipt: restored)

        #expect(policy.mode == .interactive)
    }

    @Test
    func `explicit interactive launch overrides a managed receipt`() throws {
        let receipt = try #require(self.receipt(bundleVersion: "42", codeSignatureHash: "abc123"))

        let policy = PeekabooAppLaunchPolicy(
            arguments: ["Peekaboo", PeekabooAppLaunchPolicy.interactiveArgument],
            managedReceipt: receipt,
            currentBuildReceipt: receipt)

        #expect(policy.mode == .interactive)
    }

    @Test
    func `explicit background launch persists the exact build receipt`() throws {
        let suiteName = "PeekabooAppLaunchPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let receipt = try #require(self.receipt(bundleVersion: "42", codeSignatureHash: "abc123"))
        let policy = PeekabooAppLaunchPolicy(
            arguments: ["Peekaboo", PeekabooAppLaunchPolicy.backgroundBridgeHostArgument],
            currentBuildReceipt: receipt)

        try policy.persistManagedBackgroundHostReceipt(userDefaults: defaults)

        let data = try #require(defaults.data(forKey: PeekabooAppLaunchPolicy.managedReceiptDefaultsKey))
        let stored = try JSONDecoder().decode(ManagedBackgroundHostReceipt.self, from: data)
        #expect(stored == receipt)
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
    func `background Bridge host does not start an unavailable updater`() {
        let policy = PeekabooAppLaunchPolicy(arguments: [
            "Peekaboo",
            PeekabooAppLaunchPolicy.backgroundBridgeHostArgument,
        ])

        let updater = makeUpdaterController(launchPolicy: policy)

        #expect(!updater.isAvailable)
        #expect(!updater.automaticallyChecksForUpdates)
    }

    private func receipt(bundleVersion: String, codeSignatureHash: String) -> ManagedBackgroundHostReceipt? {
        ManagedBackgroundHostReceipt(hostIdentity: PeekabooBridgeHostIdentity(
            processIdentifier: 123,
            processStartIdentity: 456,
            bundleIdentifier: "boo.peekaboo.mac",
            bundleShortVersion: "4.0.1",
            bundleVersion: bundleVersion,
            codeSignatureHash: codeSignatureHash))
    }
}
