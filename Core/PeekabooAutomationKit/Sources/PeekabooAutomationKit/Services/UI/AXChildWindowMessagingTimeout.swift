import ApplicationServices
import AXorcist

/// Applies the native AX deadline to a child window before its first probe and always clears it.
/// AX messaging timeouts are per element; setting only the owning application does not bound calls
/// such as `_AXUIElementGetWindow`, attribute reads, or actions on a returned window element.
enum AXChildWindowMessagingTimeout {
    /// Runs a child-window operation only after macOS accepts the per-element deadline.
    ///
    /// Unlike the compatibility overloads below, this checked path reports timeout setup
    /// and reset failures so exact-target callers can refuse instead of running unbounded.
    @MainActor
    static func performChecked<Result>(
        on window: Element,
        timeout: Float,
        operation: (Element) throws -> Result) throws -> Result
    {
        try window.withMessagingTimeout(timeout, operation: operation)
    }

    @MainActor
    static func perform<Result>(
        on window: Element,
        timeout: Float,
        operation: (Element) throws -> Result) rethrows -> Result
    {
        try self.perform(
            timeout: timeout,
            applyTimeout: { window.setMessagingTimeout($0) },
            operation: { try operation(window) })
    }

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
