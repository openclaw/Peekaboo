import Foundation

/// Launch-time behavior that keeps deployment-owned Bridge hosts completely unattended.
///
/// The mode is deliberately process-scoped: deployment passes one explicit argument when it
/// starts the newly installed app generation, and every presentation seam consults the same
/// immutable policy for that process lifetime.
struct PeekabooAppLaunchPolicy: Equatable, Sendable {
    static let backgroundBridgeHostArgument = "--background-bridge-host"

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

    init(arguments: [String]) {
        self.mode = arguments.dropFirst().contains(Self.backgroundBridgeHostArgument)
            ? .backgroundBridgeHost
            : .interactive
    }

    static var current: Self {
        Self(arguments: ProcessInfo.processInfo.arguments)
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

    var maximumBridgeOwnershipRetries: Int? {
        self.isBackgroundBridgeHost ? 6 : nil
    }

    var terminatesOnPermanentBridgeFailure: Bool {
        self.isBackgroundBridgeHost
    }
}
