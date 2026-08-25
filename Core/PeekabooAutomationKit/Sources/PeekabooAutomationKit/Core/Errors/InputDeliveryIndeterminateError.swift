import Foundation
import PeekabooFoundation

/// Reports that input dispatch began, but Peekaboo could not prove the final delivery destination.
/// Retrying this operation could duplicate input or invoke the same command twice.
public struct InputDeliveryIndeterminateError: LocalizedError, Sendable {
    public enum Operation: String, Sendable {
        case click
        case hotkey
        case paste
        case type
    }

    public let operation: Operation
    public let emittedUnitCount: Int?
    public let causeDescription: String?
    public let delivery: DesktopActionOutcome.Delivery?

    public init(
        operation: Operation,
        emittedUnitCount: Int? = nil,
        causeDescription: String? = nil,
        delivery: DesktopActionOutcome.Delivery? = nil)
    {
        self.operation = operation
        self.emittedUnitCount = emittedUnitCount
        self.causeDescription = causeDescription
        self.delivery = delivery
    }

    public var operationMayHaveCompleted: Bool {
        true
    }

    public var retrySafe: Bool {
        false
    }

    public var errorDescription: String? {
        let emittedUnits = self.emittedUnitCount.map { " At least \($0) input unit(s) were emitted." } ?? ""
        let cause = self.causeDescription.map { " Delivery detail: \($0)" } ?? ""
        return "\(self.operation.rawValue.capitalized) outcome is indeterminate: input may have been delivered; " +
            "do not retry blindly." + emittedUnits + cause + " Observe the target before taking another action."
    }

    /// Reconstructs the canonical failure where the indeterminate delivery evidence is owned.
    public func desktopActionFailure(
        delivery: DesktopActionOutcome.Delivery?,
        route: DesktopActionOutcome.Route = .local) -> DesktopActionFailure
    {
        DesktopActionFailure.indeterminate(
            route: route,
            delivery: self.delivery ?? delivery,
            evidence: .completionUnknown,
            unitCount: self.emittedUnitCount.flatMap { DesktopActionOutcome.DispatchUnitCount($0) },
            message: self.localizedDescription)
    }
}
