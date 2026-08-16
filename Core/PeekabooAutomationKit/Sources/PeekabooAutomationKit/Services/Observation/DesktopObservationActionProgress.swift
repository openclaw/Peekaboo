import Foundation
import PeekabooFoundation

/// The latest canonical action evidence produced while an observation is still running.
///
/// Observation callers can race the operation against a stricter outer deadline. Publishing this
/// evidence before the capture or detection phase lets that caller preserve mutation uncertainty
/// and the exact action target even when the complete observation result never returns.
public struct DesktopObservationActionProgressReceipt: Sendable, Equatable {
    public let outcome: DesktopActionOutcome
    public let targetReceipt: DesktopActionTargetReceipt?
    public let selectedLeafEvidence: [DesktopSelectedLeafEvidence]?

    public init(
        outcome: DesktopActionOutcome,
        targetReceipt: DesktopActionTargetReceipt?,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = nil)
    {
        self.outcome = outcome
        self.targetReceipt = targetReceipt
        self.selectedLeafEvidence = selectedLeafEvidence
    }
}

/// Thread-safe progress storage shared by nested observation timeout boundaries.
public final class DesktopObservationActionProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var receipt: DesktopObservationActionProgressReceipt?

    public init() {}

    public var latestReceipt: DesktopObservationActionProgressReceipt? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.receipt
    }

    public func record(_ result: UIAutomationActionResult<some Sendable>) {
        guard let outcome = result.outcome else { return }
        let receipt = DesktopObservationActionProgressReceipt(
            outcome: outcome,
            targetReceipt: result.targetIdentity?.actionTargetReceipt,
            selectedLeafEvidence: result.selectedLeafEvidence)
        self.lock.lock()
        self.receipt = receipt
        self.lock.unlock()
    }
}

/// Task-scoped channel used by a caller and the concrete observation pipeline without changing the
/// Codable observation request sent over Bridge.
public enum DesktopObservationActionProgressContext {
    @TaskLocal public static var current: DesktopObservationActionProgress?

    public static func record(_ result: UIAutomationActionResult<some Sendable>) {
        self.current?.record(result)
    }
}
