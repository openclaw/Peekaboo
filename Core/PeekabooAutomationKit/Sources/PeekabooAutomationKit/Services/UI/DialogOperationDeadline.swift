import Foundation
import PeekabooFoundation

/// Carries one caller-owned monotonic budget through local dialog services; it is never sent over the Bridge wire.
public struct DialogOperationDeadline: Sendable {
    @TaskLocal public static var current: DialogOperationDeadline?

    public let deadline: ContinuousClock.Instant
    public let timeoutSeconds: TimeInterval
    public let operationName: String

    public static func bounded(
        timeoutSeconds: TimeInterval,
        operationName: String) throws -> DialogOperationDeadline
    {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw PeekabooError.invalidInput("Dialog operation timeout must be finite and greater than zero")
        }
        let safeSeconds = min(timeoutSeconds, TimeInterval(UInt64.max / 1_000_000_000))
        let proposed = DialogOperationDeadline(
            deadline: .now.advanced(by: .seconds(safeSeconds)),
            timeoutSeconds: timeoutSeconds,
            operationName: operationName)
        if let current = self.current, current.deadline <= proposed.deadline {
            return current
        }
        return proposed
    }

    public static func resolve(
        operationName: String,
        fallbackSeconds: TimeInterval = 20) throws -> DialogOperationDeadline
    {
        if let current = self.current {
            return current
        }
        return try self.bounded(timeoutSeconds: fallbackSeconds, operationName: operationName)
    }

    public var remainingSeconds: TimeInterval {
        let remaining = ContinuousClock.now.duration(to: self.deadline).components
        return Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
    }

    public func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < self.deadline else { throw self.timeoutError }
    }

    var timeoutError: PeekabooError {
        .timeout(operation: self.operationName, duration: self.timeoutSeconds)
    }
}

@MainActor
extension DialogService {
    func runDialogOperation<Result: Sendable>(
        scope: DesktopOperationScope,
        access: DesktopOperationAccess,
        operation: () async throws -> Result) async throws -> Result
    {
        let budget = try DialogOperationDeadline.resolve(operationName: "dialog hierarchy discovery")
        return try await DialogOperationDeadline.$current.withValue(budget) {
            try budget.check()
            return try await self.operationLaneCoordinator.run(scope: scope, access: access, operation: operation)
        }
    }
}
