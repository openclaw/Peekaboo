import CoreGraphics

/// Raw exact-window evidence for a click with an explicit accessibility-value delivery policy.
/// Construction preserves both inputs without validation; the executing service owns validation
/// after its existing capability checks. Bounds are not inferred from the identity's captured bounds.
public struct ExactWindowClickEvidence: Sendable {
    public let identity: WindowMutationIdentity
    public let bounds: CGRect

    public init(identity: WindowMutationIdentity, bounds: CGRect) {
        self.identity = identity
        self.bounds = bounds
    }
}
