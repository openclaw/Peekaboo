import Foundation

/// Main error type for Peekaboo operations
public nonisolated enum PeekabooError: LocalizedError, StandardizedError, PeekabooErrorProtocol {
    // Permission errors
    case permissionDeniedScreenRecording
    case permissionDeniedAccessibility
    case permissionDeniedEventSynthesizing

    // App and window errors
    case appNotFound(String)
    case ambiguousAppIdentifier(String, suggestions: [String])
    case windowNotFound(criteria: String? = nil)
    case displayNotFound

    // Element errors
    case elementNotFound(String)
    case ambiguousElement(String)

    // Menu errors
    case menuNotFound(String)
    case menuItemNotFound(String)

    // Session errors
    case sessionNotFound(String)
    case snapshotNotFound(String)
    /// No snapshot could be resolved at all (nothing captured, or the cache is empty).
    /// Unlike `snapshotNotFound`, the associated value is a full user-facing message, not an ID.
    case snapshotNotAvailable(String)
    case snapshotStale(String)

    // Operation errors
    case captureTimeout
    case captureFailed(String)
    case clickFailed(String)
    case typeFailed(String)
    case invalidCoordinates
    case fileIOError(String)
    case commandFailed(String)
    case timeout(String)

    // Input errors
    case invalidInput(String)
    case encodingError(String)

    // AI errors
    case noAIProviderAvailable
    case aiProviderError(String)

    /// Service errors
    case serviceUnavailable(String)

    // Network errors
    case networkError(String)
    case apiError(code: Int, message: String)
    case authenticationFailed(String)
    case rateLimited(retryAfter: TimeInterval?, message: String)
    case serverError(String)

    // Additional errors
    case notFound(String)
    case permissionDenied(String)
    case notImplemented(String)

    /// Generic errors - removed context since it can't be Sendable
    case operationError(message: String)

    public var errorDescription: String? {
        switch self {
        case .permissionDeniedScreenRecording:
            return "Screen Recording permission is required"
        case .permissionDeniedAccessibility:
            return "Accessibility permission is required"
        case .permissionDeniedEventSynthesizing:
            return "Event-synthesizing permission is required"
        case let .appNotFound(name):
            return "Application '\(name)' not found"
        case let .ambiguousAppIdentifier(name, suggestions):
            return "Multiple apps match '\(name)'. Did you mean: \(suggestions.joined(separator: ", "))"
        case let .windowNotFound(criteria):
            if let criteria {
                return "Window not found: \(criteria)"
            }
            return "Window not found"
        case .displayNotFound:
            return "Display not found"
        case let .elementNotFound(id):
            return "Element not found: \(id)"
        case let .ambiguousElement(id):
            return "Multiple elements match: \(id)"
        case let .menuNotFound(app):
            return "Menu not found for application: \(app)"
        case let .menuItemNotFound(item):
            return "Menu item not found: \(item)"
        case let .sessionNotFound(id):
            return "Session not found or expired: \(id)"
        case let .snapshotNotFound(id):
            return "Snapshot not found or expired: \(id)"
        case let .snapshotNotAvailable(message):
            return message
        case let .snapshotStale(reason):
            return "Snapshot is stale: \(reason). Re-run peekaboo see to refresh."
        case .captureTimeout:
            return "Screen capture timed out"
        case let .captureFailed(reason):
            return "Capture failed: \(reason)"
        case let .clickFailed(reason):
            return "Click failed: \(reason)"
        case let .typeFailed(reason):
            return "Type failed: \(reason)"
        case .invalidCoordinates:
            return "Invalid coordinates provided"
        case let .fileIOError(reason):
            return "File I/O error: \(reason)"
        case let .commandFailed(reason):
            return "Command failed: \(reason)"
        case let .timeout(reason):
            return "Operation timed out: \(reason)"
        case let .invalidInput(message):
            return "Invalid input: \(message)"
        case let .encodingError(message):
            return "Encoding error: \(message)"
        case .noAIProviderAvailable:
            return "No AI provider available"
        case let .aiProviderError(message):
            return "AI provider error: \(message)"
        case let .serviceUnavailable(message):
            return "Service unavailable: \(message)"
        case let .networkError(message):
            return "Network error: \(message)"
        case let .apiError(code, message):
            return "API error (\(code)): \(message)"
        case let .authenticationFailed(message):
            return "Authentication failed: \(message)"
        case let .rateLimited(retryAfter, message):
            if let retryAfter {
                return "Rate limited (retry after \(Int(retryAfter))s): \(message)"
            }
            return "Rate limited: \(message)"
        case let .serverError(message):
            return "Server error: \(message)"
        case let .notFound(message):
            return "Not found: \(message)"
        case let .permissionDenied(message):
            return "Permission denied: \(message)"
        case let .notImplemented(message):
            return "Not implemented: \(message)"
        case let .operationError(message):
            return message
        }
    }

    /// StandardizedError conformance
    public var code: StandardErrorCode {
        switch self {
        case .permissionDeniedScreenRecording:
            .screenRecordingPermissionDenied
        case .permissionDeniedAccessibility:
            .accessibilityPermissionDenied
        case .permissionDeniedEventSynthesizing:
            .eventSynthesizingPermissionDenied
        case .appNotFound:
            .applicationNotFound
        case .ambiguousAppIdentifier:
            .ambiguousAppIdentifier
        case .windowNotFound:
            .windowNotFound
        case .displayNotFound:
            .invalidDisplayIndex
        case .elementNotFound:
            .elementNotFound
        case .ambiguousElement:
            .elementNotFound
        case .menuNotFound:
            .menuNotFound
        case .menuItemNotFound:
            .menuNotFound
        case .sessionNotFound:
            .sessionNotFound
        case .snapshotNotFound:
            .snapshotNotFound
        case .snapshotNotAvailable:
            .snapshotNotFound
        case .snapshotStale:
            .snapshotNotFound
        case .captureTimeout:
            .timeout
        case .captureFailed:
            .captureFailed
        case .clickFailed:
            .interactionFailed
        case .typeFailed:
            .interactionFailed
        case .invalidCoordinates:
            .invalidCoordinates
        case .fileIOError:
            .fileIOError
        case .commandFailed:
            .interactionFailed
        case .timeout:
            .timeout
        case .invalidInput:
            .invalidInput
        case .encodingError:
            .unknownError
        case .noAIProviderAvailable:
            .aiProviderUnavailable
        case .aiProviderError:
            .aiAnalysisFailed
        case .serviceUnavailable:
            .unknownError
        case .operationError:
            .unknownError
        case .networkError:
            .unknownError
        case .apiError:
            .unknownError
        case .authenticationFailed:
            .unknownError
        case .rateLimited:
            .unknownError
        case .serverError:
            .unknownError
        case .notFound:
            .unknownError
        case .permissionDenied:
            .unknownError
        case .notImplemented:
            .unknownError
        }
    }

    public var userMessage: String {
        self.errorDescription ?? "Unknown error"
    }

    public var context: [String: String] {
        switch self {
        case let .ambiguousAppIdentifier(name, suggestions):
            return ["identifier": name, "suggestions": suggestions.joined(separator: ", ")]
        case let .appNotFound(name):
            return ["app": name]
        case let .elementNotFound(id):
            return ["element": id]
        case let .ambiguousElement(id):
            return ["element": id]
        case let .menuNotFound(app):
            return ["application": app]
        case let .menuItemNotFound(item):
            return ["item": item]
        case let .sessionNotFound(id):
            return ["session_id": id]
        case let .snapshotNotFound(id):
            return ["snapshot_id": id]
        case let .snapshotNotAvailable(message):
            return ["message": message]
        case let .captureFailed(reason):
            return ["reason": reason]
        case let .clickFailed(reason):
            return ["reason": reason]
        case let .typeFailed(reason):
            return ["reason": reason]
        case let .fileIOError(reason):
            return ["reason": reason]
        case let .commandFailed(reason):
            return ["reason": reason]
        case let .timeout(reason):
            return ["reason": reason]
        case let .invalidInput(message):
            return ["message": message]
        case let .encodingError(message):
            return ["message": message]
        case let .aiProviderError(message):
            return ["message": message]
        case let .serviceUnavailable(message):
            return ["message": message]
        case let .operationError(message):
            return ["message": message]
        case let .windowNotFound(criteria):
            if let criteria {
                return ["criteria": criteria]
            }
            return [:]
        case let .networkError(message):
            return ["message": message]
        case let .apiError(code, message):
            return ["code": "\(code)", "message": message]
        case let .authenticationFailed(message):
            return ["message": message]
        case let .rateLimited(retryAfter, message):
            if let retryAfter {
                return ["retryAfter": "\(retryAfter)", "message": message]
            }
            return ["message": message]
        case let .serverError(message):
            return ["message": message]
        case let .notFound(message):
            return ["message": message]
        case let .permissionDenied(message):
            return ["message": message]
        case let .notImplemented(message):
            return ["message": message]
        default:
            return [:]
        }
    }

    /// Error code for structured error responses
    public var errorCode: String {
        self.code.rawValue
    }

    // MARK: - PeekabooErrorProtocol Conformance

    public var category: ErrorCategory {
        switch self {
        case .permissionDeniedScreenRecording, .permissionDeniedAccessibility, .permissionDeniedEventSynthesizing:
            .permissions
        case .appNotFound, .ambiguousAppIdentifier, .windowNotFound, .displayNotFound,
             .elementNotFound, .ambiguousElement, .menuNotFound, .menuItemNotFound,
             .clickFailed, .typeFailed, .invalidCoordinates:
            .automation
        case .sessionNotFound, .snapshotNotFound, .snapshotNotAvailable, .snapshotStale:
            .session
        case .captureTimeout, .captureFailed, .timeout:
            .automation
        case .fileIOError:
            .io
        case .commandFailed:
            .automation
        case .invalidInput, .encodingError:
            .validation
        case .noAIProviderAvailable, .aiProviderError:
            .ai
        case .serviceUnavailable:
            .configuration
        case .operationError:
            .unknown
        case .networkError, .apiError, .authenticationFailed, .rateLimited, .serverError:
            .network
        case .notFound:
            .unknown
        case .permissionDenied:
            .permissions
        case .notImplemented:
            .unknown
        }
    }

    public var suggestedAction: String? {
        switch self {
        case .permissionDeniedScreenRecording:
            "Grant Screen Recording permission in System Settings → Privacy & Security → Screen Recording"
        case .permissionDeniedAccessibility:
            "Grant Accessibility permission in System Settings → Privacy & Security → Accessibility"
        case .permissionDeniedEventSynthesizing:
            "Grant event-synthesizing access in System Settings → Privacy & Security → Accessibility"
        case let .ambiguousAppIdentifier(_, suggestions):
            "Try one of: \(suggestions.joined(separator: ", "))"
        case .snapshotNotAvailable:
            "Run 'peekaboo see' to capture a fresh UI snapshot"
        case .noAIProviderAvailable:
            "Configure an AI provider and API key in settings"
        case .aiProviderError:
            "Check your API key and network connection"
        case .serviceUnavailable:
            "Ensure all required services are running"
        default:
            nil
        }
    }
}

// MARK: - Convenience Factory Methods

extension PeekabooError {
    /// Create a capture failed error
    public static func captureFailed(reason: String) -> PeekabooError {
        .captureFailed(reason)
    }

    /// Create an interaction failed error
    public static func interactionFailed(action: String, reason: String) -> PeekabooError {
        .operationError(message: "Failed to perform \(action): \(reason)")
    }

    /// Create a timeout error
    public static func timeout(operation: String, duration: TimeInterval) -> PeekabooError {
        .timeout("Operation '\(operation)' timed out after \(Int(duration)) seconds")
    }

    /// Create an ambiguous app identifier error
    public static func ambiguousAppIdentifier(_ identifier: String, matches: [String]) -> PeekabooError {
        .ambiguousAppIdentifier(identifier, suggestions: matches)
    }

    /// Create an invalid input error
    public static func invalidInput(field: String, reason: String) -> PeekabooError {
        .invalidInput("Invalid \(field): \(reason)")
    }

    /// Create an invalid coordinates error
    public static func invalidCoordinates(x: Double, y: Double) -> PeekabooError {
        .invalidCoordinates
    }
}
