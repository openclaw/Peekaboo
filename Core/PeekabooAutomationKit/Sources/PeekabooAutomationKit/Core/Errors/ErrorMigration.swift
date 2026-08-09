import Foundation
import PeekabooFoundation

// MARK: - Error Migration Support

/// Temporary struct to support gradual migration from struct-based errors to PeekabooError
public struct NotFoundError {
    public let code: StandardErrorCode
    public let userMessage: String
    public let context: [String: String]

    public init(code: StandardErrorCode, userMessage: String, context: [String: String]) {
        self.code = code
        self.userMessage = userMessage
        self.context = context
    }

    /// Factory methods that return PeekabooError
    public static func application(_ identifier: String) -> PeekabooError {
        .appNotFound(identifier)
    }

    public static func window(app: String, index: Int? = nil) -> PeekabooError {
        .windowNotFound()
    }

    public static func element(_ description: String) -> PeekabooError {
        .elementNotFound(description)
    }

    public static func snapshot(_ id: String) -> PeekabooError {
        .snapshotNotFound(id)
    }
}

/// Make NotFoundError throwable by converting to PeekabooError
extension NotFoundError: Error {
    public var asPeekabooError: PeekabooError {
        switch self.code {
        case .applicationNotFound:
            if let app = context["identifier"] ?? context["app"] {
                return .appNotFound(app)
            }
            return .operationError(message: self.userMessage)
        case .windowNotFound:
            return .windowNotFound(criteria: nil)
        case .elementNotFound:
            if let element = context["element"] {
                return .elementNotFound(element)
            }
            return .operationError(message: self.userMessage)
        case .snapshotNotFound:
            if let id = context["snapshot_id"] {
                return .snapshotNotFound(id)
            }
            return .operationError(message: self.userMessage)
        case .sessionNotFound:
            if let id = context["session_id"] {
                return .sessionNotFound(id)
            }
            return .operationError(message: self.userMessage)
        case .menuNotFound:
            if let app = context["application"] {
                return .menuNotFound(app)
            }
            return .operationError(message: self.userMessage)
        default:
            return .operationError(message: self.userMessage)
        }
    }
}

/// Temporary struct for PermissionError migration
public enum PermissionError {
    public static func screenRecording() -> PeekabooError {
        .permissionDeniedScreenRecording
    }

    public static func accessibility() -> PeekabooError {
        .permissionDeniedAccessibility
    }
}
