import Foundation

public enum ChromeChannelIdentity: String, Sendable, CaseIterable, Codable {
    case stable
    case beta
    case dev
    case canary

    public init?(exactBundleIdentifier: String?) {
        switch exactBundleIdentifier?.lowercased() {
        case "com.google.chrome": self = .stable
        case "com.google.chrome.beta": self = .beta
        case "com.google.chrome.dev": self = .dev
        case "com.google.chrome.canary": self = .canary
        default: return nil
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .stable: "com.google.Chrome"
        case .beta: "com.google.Chrome.beta"
        case .dev: "com.google.Chrome.dev"
        case .canary: "com.google.Chrome.canary"
        }
    }

    public var profileDirectoryName: String {
        switch self {
        case .stable: "Chrome"
        case .beta: "Chrome Beta"
        case .dev: "Chrome Dev"
        case .canary: "Chrome Canary"
        }
    }

    public func matches(bundleIdentifier: String?) -> Bool {
        Self(exactBundleIdentifier: bundleIdentifier) == self
    }
}

public enum BrowserConnectionTiming {
    /// One browser connection request, including user approval, MCP startup, and the read-only probe.
    public static let endToEndTimeoutSeconds: TimeInterval = 90
    /// Chrome approval is bounded within the end-to-end deadline so MCP startup retains time to complete.
    public static let approvalTimeoutSeconds: TimeInterval = 60
    /// Bridge transport includes a small response/signing margin beyond the host-owned connection deadline.
    public static let bridgeTransportTimeoutSeconds: TimeInterval = 95
}
