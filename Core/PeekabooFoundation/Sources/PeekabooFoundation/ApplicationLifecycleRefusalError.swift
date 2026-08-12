import Foundation

public struct ApplicationLifecycleFailureMetadata: Equatable, Sendable {
    public let effect: String
    public let errorCode: StandardErrorCode
    public let hint: String?
    public let retrySafe: Bool
    public let mutationDispatched: Bool

    public init(
        effect: String,
        errorCode: StandardErrorCode,
        hint: String? = nil,
        retrySafe: Bool,
        mutationDispatched: Bool)
    {
        self.effect = effect
        self.errorCode = errorCode
        self.hint = hint
        self.retrySafe = retrySafe
        self.mutationDispatched = mutationDispatched
    }
}

public protocol ApplicationLifecycleFailureMetadataProviding: Sendable {
    var applicationLifecycleFailureMetadata: ApplicationLifecycleFailureMetadata? { get }
}

public protocol ApplicationLifecycleRefusalMetadataProviding: ApplicationLifecycleFailureMetadataProviding {
    var applicationLifecycleRefusalHint: String? { get }
}

extension ApplicationLifecycleRefusalMetadataProviding {
    public var applicationLifecycleFailureMetadata: ApplicationLifecycleFailureMetadata? {
        guard let hint = self.applicationLifecycleRefusalHint else { return nil }
        return ApplicationLifecycleFailureMetadata(
            effect: "refused",
            errorCode: .interactionFailed,
            hint: hint,
            retrySafe: true,
            mutationDispatched: false)
    }
}

public struct ApplicationLifecycleRefusalError: LocalizedError, StandardizedError, Equatable, Sendable,
    ApplicationLifecycleRefusalMetadataProviding
{
    public static let backgroundLaunchContext = "application_lifecycle_refusal:foreground"
    public static let unhideContext = "application_lifecycle_refusal:unhide"

    public let userMessage: String
    public let hint: String
    public let bridgeContext: String

    public var applicationLifecycleRefusalHint: String? {
        self.hint
    }

    public var code: StandardErrorCode {
        .interactionFailed
    }

    public var context: [String: String] {
        [
            "effect": "refused",
            "hint": self.hint,
            "mutation_dispatched": "false",
            "retry_safe": "true",
            "bridge_context": self.bridgeContext,
        ]
    }

    public static func backgroundLaunch(_ reason: String) -> Self {
        Self(
            userMessage: reason,
            hint: "Retry with --foreground in the CLI or foreground=true in MCP.",
            bridgeContext: self.backgroundLaunchContext)
    }

    public static func unhideRequiresForegroundConsent() -> Self {
        Self(
            userMessage: "Unhiding an application can bring its windows forward and requires " +
                "explicit foreground consent.",
            hint: "Retry with --activate in the CLI or foreground=true in MCP.",
            bridgeContext: self.unhideContext)
    }

    public static func legacyBridgeUnhide() -> Self {
        Self(
            userMessage: "The legacy identifier-only Bridge unhide request carries no foreground consent " +
                "and was refused before dispatch.",
            hint: "Use app unhide --activate or the MCP app tool with foreground=true.",
            bridgeContext: self.unhideContext)
    }

    public static func hint(forBridgeContext context: String?) -> String? {
        switch context {
        case self.backgroundLaunchContext:
            "Retry with --foreground in the CLI or foreground=true in MCP."
        case self.unhideContext:
            "Retry with --activate in the CLI or foreground=true in MCP."
        default:
            nil
        }
    }
}

public struct ApplicationLifecycleReadOnlyFailureError: LocalizedError, StandardizedError, Sendable,
    ApplicationLifecycleFailureMetadataProviding
{
    public static let bridgeContext = "application_lifecycle_read_only:no_dispatch"

    public let underlyingError: PeekabooError

    public init(_ underlyingError: PeekabooError) {
        self.underlyingError = underlyingError
    }

    public var code: StandardErrorCode {
        self.underlyingError.code
    }

    public var userMessage: String {
        self.underlyingError.localizedDescription
    }

    public var context: [String: String] {
        [
            "effect": "unverifiable",
            "mutation_dispatched": "false",
            "retry_safe": "true",
            "bridge_context": Self.bridgeContext,
        ]
    }

    public var applicationLifecycleFailureMetadata: ApplicationLifecycleFailureMetadata? {
        ApplicationLifecycleFailureMetadata(
            effect: "unverifiable",
            errorCode: self.code,
            retrySafe: true,
            mutationDispatched: false)
    }
}
