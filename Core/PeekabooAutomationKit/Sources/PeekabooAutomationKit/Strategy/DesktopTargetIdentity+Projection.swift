import Foundation

extension DesktopTargetIdentity {
    /// Transport-neutral, lossless JSON projection of one stable desktop target.
    public struct Projection: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case process
            case window
        }

        public let kind: Kind
        public let processIdentifier: Int32
        public let processStartIdentityDecimal: String
        public let windowID: Int?

        public init(_ identity: DesktopTargetIdentity) {
            let processIdentity = identity.processIdentity
            self.kind = identity.exactWindow == nil ? .process : .window
            self.processIdentifier = processIdentity.processIdentifier
            self.processStartIdentityDecimal = String(processIdentity.processStartIdentity)
            self.windowID = identity.exactWindow?.identity.windowID
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case processIdentifier = "pid"
            case processStartIdentityDecimal = "process_start_identity_decimal"
            case windowID = "window_id"
        }
    }

    public var projection: Projection {
        Projection(self)
    }
}
