import Foundation

// MARK: - Error Code Protocol

/// Standard error codes used across Peekaboo
public enum StandardErrorCode: String, Codable, Sendable, Equatable {
    // Permission errors
    case screenRecordingPermissionDenied = "PERMISSION_DENIED_SCREEN_RECORDING"
    case accessibilityPermissionDenied = "PERMISSION_DENIED_ACCESSIBILITY"
    case eventSynthesizingPermissionDenied = "PERMISSION_DENIED_EVENT_SYNTHESIZING"

    // Not found errors
    case applicationNotFound = "APP_NOT_FOUND"
    case windowNotFound = "WINDOW_NOT_FOUND"
    case elementNotFound = "ELEMENT_NOT_FOUND"
    case sessionNotFound = "SESSION_NOT_FOUND"
    case snapshotNotFound = "SNAPSHOT_NOT_FOUND"
    case snapshotStale = "SNAPSHOT_STALE"
    case fileNotFound = "FILE_NOT_FOUND"
    case menuNotFound = "MENU_NOT_FOUND"

    // Operation errors
    case captureFailed = "CAPTURE_FAILED"
    case interactionFailed = "INTERACTION_FAILED"
    case browserTargetLocked = "BROWSER_TARGET_LOCKED"
    case accessibilityIncomplete = "ACCESSIBILITY_INCOMPLETE"
    case timeout = "TIMEOUT"
    case cancelled = "CANCELLED"

    // Input errors
    case invalidInput = "INVALID_INPUT"
    case invalidCoordinates = "INVALID_COORDINATES"
    case invalidDisplayIndex = "INVALID_DISPLAY_INDEX"
    case invalidWindowIndex = "INVALID_WINDOW_INDEX"
    case ambiguousAppIdentifier = "AMBIGUOUS_APP_IDENTIFIER"

    // System errors
    case fileIOError = "FILE_IO_ERROR"
    case configurationError = "CONFIGURATION_ERROR"
    case unknownError = "UNKNOWN_ERROR"

    // AI errors
    case aiProviderUnavailable = "AI_PROVIDER_UNAVAILABLE"
    case aiAnalysisFailed = "AI_ANALYSIS_FAILED"
}

// MARK: - Base Error Protocol

/// Base protocol for standardized Peekaboo errors
public protocol StandardizedError: LocalizedError, Sendable {
    nonisolated var code: StandardErrorCode { get }
    nonisolated var userMessage: String { get }
    nonisolated var context: [String: String] { get }
}

extension StandardizedError {
    public nonisolated var errorDescription: String? {
        userMessage
    }
}

// MARK: - Error Context Builder

/// Helper for building error context
public struct ErrorContext {
    private var items: [String: String] = [:]

    public init() {}

    public mutating func add(_ key: String, _ value: String) {
        self.items[key] = value
    }

    public mutating func add(_ key: String, _ value: Any) {
        self.items[key] = String(describing: value)
    }

    public func build() -> [String: String] {
        self.items
    }
}

// MARK: - Common Error Types

/// Operation failure errors - using PeekabooError for simpler API
public typealias OperationError = PeekabooError

// MARK: - Error Conversion

/// Convert various error types to standardized errors
public enum ErrorStandardizer {
    public static func standardize(_ error: any Error) -> any StandardizedError {
        // If already standardized, return as-is
        if let standardized = error as? any StandardizedError {
            return standardized
        }

        // Convert known error types
        switch error {
        case let peekabooError as PeekabooError:
            return peekabooError
        case let nsError as NSError:
            return self.standardizeNSError(nsError)
        default:
            return PeekabooError.operationError(message: error.localizedDescription)
        }
    }

    private static func standardizeNSError(_ error: NSError) -> any StandardizedError {
        // Handle common Cocoa errors
        switch error.domain {
        case NSCocoaErrorDomain:
            if error.code == NSFileNoSuchFileError {
                let path = error.userInfo[NSFilePathErrorKey] as? String ?? "unknown"
                return PeekabooError.fileIOError("File not found: \(path)")
            }
        default:
            break
        }

        return PeekabooError.operationError(message: error.localizedDescription)
    }
}

// MARK: - Error Recovery Suggestions

extension StandardizedError {
    public nonisolated var recoverySuggestion: String? {
        switch code {
        case .screenRecordingPermissionDenied:
            "Grant Screen Recording permission in System Settings"
        case .accessibilityPermissionDenied:
            "Grant Accessibility permission in System Settings"
        case .eventSynthesizingPermissionDenied:
            "Grant event-synthesizing access in System Settings > Privacy & Security > Accessibility"
        case .applicationNotFound:
            "Ensure the application is installed and running"
        case .windowNotFound:
            "Check that the application has open windows"
        case .accessibilityIncomplete:
            "Run one fresh exact-window Accessibility observation, then use screenshot/OCR if it remains incomplete"
        case .timeout:
            "Try the operation again or increase the timeout"
        case .ambiguousAppIdentifier:
            "Use a more specific application name or bundle ID"
        default:
            nil
        }
    }
}
