import Foundation
import UniformTypeIdentifiers

/// A content-free observation of this process's native clipboard read policy, not a permission grant.
public struct ClipboardReadAccessStatus: Encodable, Equatable, Sendable {
    public enum Policy: String, Codable, Sendable {
        case systemDefault = "default"
        case ask
        case alwaysAllow = "always_allow"
        case alwaysDeny = "always_deny"
        case notRequired = "not_required"
        case unavailableOnOS = "unavailable_on_this_os"
        case unknown
    }

    public let policy: Policy

    public init(policy: Policy) {
        self.policy = policy
    }

    public var readAdmitted: Bool {
        switch self.policy {
        case .alwaysAllow, .notRequired, .unavailableOnOS: true
        case .systemDefault, .ask, .alwaysDeny, .unknown: false
        }
    }

    public var policyAvailable: Bool {
        self.policy != .notRequired && self.policy != .unavailableOnOS
    }

    private enum CodingKeys: String, CodingKey {
        case policy
        case policyAvailable = "policy_available"
        case readAdmitted = "read_admitted"
        case readerContext = "reader_context"
        case contentsRead = "contents_read"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.policy, forKey: .policy)
        try container.encode(self.policyAvailable, forKey: .policyAvailable)
        try container.encode(self.readAdmitted, forKey: .readAdmitted)
        try container.encode("caller_local", forKey: .readerContext)
        try container.encode(false, forKey: .contentsRead)
    }
}

/// Additive capability; custom clipboard providers keep their existing source contract.
@MainActor
public protocol ClipboardReadAccessProviding: ClipboardServiceProtocol {
    func readAccessStatus() -> ClipboardReadAccessStatus
    func get(prefer uti: UTType?, allowPrompt: Bool) throws -> ClipboardReadResult?
    func save(slot: String, allowPrompt: Bool) throws
}
