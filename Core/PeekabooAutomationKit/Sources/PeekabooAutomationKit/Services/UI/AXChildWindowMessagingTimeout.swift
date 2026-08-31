import ApplicationServices

/// Applies and clears an unchecked per-element AX deadline for detached workers.
/// Raw workers run off MainActor and cannot use AXorcist's checked `Element.withMessagingTimeout` scope.
/// Application deadlines do not cover returned child references; each child needs its own scope.
enum AXChildWindowMessagingTimeout {
    static func perform<Result>(
        on window: AXUIElement,
        timeout: Float,
        operation: (AXUIElement) throws -> Result) rethrows -> Result
    {
        try self.perform(
            timeout: timeout,
            applyTimeout: { AXUIElementSetMessagingTimeout(window, $0) },
            operation: { try operation(window) })
    }

    static func perform<Result>(
        timeout: Float,
        applyTimeout: (Float) -> Void,
        operation: () throws -> Result) rethrows -> Result
    {
        precondition(timeout > 0)
        applyTimeout(timeout)
        defer { applyTimeout(0) }
        return try operation()
    }
}
