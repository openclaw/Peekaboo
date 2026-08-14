import ApplicationServices
import AXorcist

/// Applies the native AX deadline to a child window before its first probe and always clears it.
/// AX messaging timeouts are per element; setting only the owning application does not bound calls
/// such as `_AXUIElementGetWindow`, attribute reads, or actions on a returned window element.
enum AXChildWindowMessagingTimeout {
    /// Runs a child-window operation only after macOS accepts the per-element deadline.
    ///
    /// This compatibility owner keeps Peekaboo's versioned SwiftPM package on AXorcist 0.1.6.
    /// Delete it after an explicitly authorized AXorcist semantic-version release exposes the
    /// equivalent checked `Element.withMessagingTimeout` scope.
    @MainActor
    static func performChecked<Value>(
        on window: Element,
        timeout: Float,
        operation: (Element) throws -> Value) throws -> Value
    {
        guard AXChildWindowMessagingTimeoutRegistry.begin(window) else {
            throw AXChildWindowMessagingTimeoutError.nestedScope
        }
        defer { AXChildWindowMessagingTimeoutRegistry.end(window) }
        return try self.performChecked(
            timeout: timeout,
            applyTimeout: { AXUIElementSetMessagingTimeout(window.underlyingElement, $0) },
            operation: { try operation(window) })
    }

    static func performChecked<Value>(
        timeout: Float,
        applyTimeout: (Float) -> AXError,
        operation: () throws -> Value) throws -> Value
    {
        guard timeout.isFinite, timeout > 0 else {
            throw AXChildWindowMessagingTimeoutError.invalidTimeout
        }

        let armResult = applyTimeout(timeout)
        guard armResult == .success else {
            throw AXChildWindowMessagingTimeoutError.setupFailure(code: armResult.rawValue)
        }

        let operationResult: Result<Value, any Error> = Result {
            try operation()
        }
        let resetResult = applyTimeout(0)
        guard resetResult == .success else {
            throw AXChildWindowMessagingTimeoutError.resetFailure(code: resetResult.rawValue)
        }
        return try operationResult.get()
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

enum AXChildWindowMessagingTimeoutError: Error, Equatable, Sendable {
    case invalidTimeout
    case nestedScope
    case setupFailure(code: Int32)
    case resetFailure(code: Int32)
}

@MainActor
private enum AXChildWindowMessagingTimeoutRegistry {
    private enum Key: Hashable {
        case systemWide
        case element(ObjectIdentifier)
    }

    private static let systemWideElement = AXUIElementCreateSystemWide()
    private static var activeElements: Set<Key> = []

    static func begin(_ element: Element) -> Bool {
        self.activeElements.insert(self.key(for: element)).inserted
    }

    static func end(_ element: Element) {
        self.activeElements.remove(self.key(for: element))
    }

    private static func key(for element: Element) -> Key {
        if CFEqual(element.underlyingElement, self.systemWideElement) {
            return .systemWide
        }
        return .element(ObjectIdentifier(element.underlyingElement))
    }
}
