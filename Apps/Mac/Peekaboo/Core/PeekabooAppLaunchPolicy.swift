import AppKit
import Foundation
import PeekabooBridge

struct ManagedBackgroundHostReceipt: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let bundleVersion: String
    let codeSignatureHash: String

    init?(hostIdentity: PeekabooBridgeHostIdentity) {
        guard let bundleIdentifier = hostIdentity.bundleIdentifier,
              let bundleVersion = hostIdentity.bundleVersion,
              let codeSignatureHash = hostIdentity.codeSignatureHash
        else { return nil }
        self.bundleIdentifier = bundleIdentifier
        self.bundleVersion = bundleVersion
        self.codeSignatureHash = codeSignatureHash
    }
}

private enum ManagedBackgroundHostReceiptError: LocalizedError {
    case missingSignedBuildIdentity

    var errorDescription: String? {
        "The current app has no complete signed build identity"
    }
}

/// Launch-time behavior that keeps deployment-owned Bridge hosts completely unattended.
///
/// Deployment passes one explicit argument for the newly installed app generation. That exact
/// signed build records a receipt so a main-app login registration can preserve unattended mode
/// without making a rolled-back or separately updated bundle inherit it.
struct PeekabooAppLaunchPolicy: Equatable, Sendable {
    static let backgroundBridgeHostArgument = "--background-bridge-host"
    static let interactiveArgument = "--interactive"
    static let managedReceiptDefaultsKey = "peekaboo.managedBackgroundBridgeHostReceipt"

    enum Mode: Equatable, Sendable {
        case interactive
        case backgroundBridgeHost
    }

    enum PresentationIntent: Equatable, Sendable {
        case automatic
        case reopen
        case explicitUser
    }

    let mode: Mode
    private let explicitlyRequestedBackgroundHost: Bool
    private let currentBuildReceipt: ManagedBackgroundHostReceipt?

    init(
        arguments: [String],
        managedReceipt: ManagedBackgroundHostReceipt? = nil,
        currentBuildReceipt: ManagedBackgroundHostReceipt? = nil)
    {
        let launchArguments = arguments.dropFirst()
        let explicitlyRequestedBackgroundHost = launchArguments.contains(Self.backgroundBridgeHostArgument)
        let explicitlyRequestedInteractive = launchArguments.contains(Self.interactiveArgument)
        self.explicitlyRequestedBackgroundHost = explicitlyRequestedBackgroundHost
        self.currentBuildReceipt = currentBuildReceipt
        self.mode = if explicitlyRequestedBackgroundHost {
            .backgroundBridgeHost
        } else if explicitlyRequestedInteractive {
            .interactive
        } else if let managedReceipt, managedReceipt == currentBuildReceipt {
            .backgroundBridgeHost
        } else {
            .interactive
        }
    }

    @MainActor
    static var current: Self {
        let currentBuildReceipt = ManagedBackgroundHostReceipt(hostIdentity: .current())
        let managedReceipt = UserDefaults.standard.data(forKey: Self.managedReceiptDefaultsKey)
            .flatMap { try? JSONDecoder().decode(ManagedBackgroundHostReceipt.self, from: $0) }
        return Self(
            arguments: ProcessInfo.processInfo.arguments,
            managedReceipt: managedReceipt,
            currentBuildReceipt: currentBuildReceipt)
    }

    func persistManagedBackgroundHostReceipt(userDefaults: UserDefaults = .standard) throws {
        guard self.explicitlyRequestedBackgroundHost else { return }
        guard let currentBuildReceipt else {
            throw ManagedBackgroundHostReceiptError.missingSignedBuildIdentity
        }
        let encoded = try JSONEncoder().encode(currentBuildReceipt)
        userDefaults.set(encoded, forKey: Self.managedReceiptDefaultsKey)
    }

    var isBackgroundBridgeHost: Bool {
        self.mode == .backgroundBridgeHost
    }

    func allowsPresentation(_ intent: PresentationIntent) -> Bool {
        !self.isBackgroundBridgeHost || intent == .explicitUser
    }

    var allowsAPIKeyNudge: Bool {
        !self.isBackgroundBridgeHost
    }

    var allowsPermissionsOnboarding: Bool {
        !self.isBackgroundBridgeHost
    }

    var suppressesAutomaticScenePresentation: Bool {
        self.isBackgroundBridgeHost
    }

    var disablesSceneRestoration: Bool {
        self.isBackgroundBridgeHost
    }

    var initialActivationPolicy: NSApplication.ActivationPolicy? {
        self.isBackgroundBridgeHost ? .accessory : nil
    }

    var allowsUpdaterStartup: Bool {
        !self.isBackgroundBridgeHost
    }

    var maximumBridgeOwnershipRetries: Int? {
        self.isBackgroundBridgeHost ? 6 : nil
    }

    var terminatesOnPermanentBridgeFailure: Bool {
        self.isBackgroundBridgeHost
    }
}
