import Foundation
import PeekabooFoundation
import Tachikoma

// MARK: - Tool Helper Functions

/// Common helper functions used across tool implementations
@available(macOS 14.0, *)
extension PeekabooAgentService {
    /// Handle tool errors with consistent formatting and error enhancement
    func handleToolError(
        _ error: any Error,
        for toolName: String,
        in context: any PeekabooServiceProviding) async -> AnyAgentToolValue
    {
        // Log the error
        context.logging.error("Tool \(toolName) failed: \(error.localizedDescription)", category: "Tool")

        // Convert to PeekabooError if possible
        let peekabooError: PeekabooError = if let pError = error as? PeekabooError {
            pError
        } else {
            .operationError(message: error.localizedDescription)
        }

        // Get enhanced error information
        let errorInfo = self.enhanceError(peekabooError, for: toolName)

        // Build error message
        var errorMessage = errorInfo.message

        if let suggestion = errorInfo.suggestion {
            errorMessage += "\n\nSuggestion: \(suggestion)"
        }

        if !errorInfo.metadata.isEmpty {
            errorMessage += "\n\nDetails:"
            for (key, value) in errorInfo.metadata {
                errorMessage += "\n• \(key): \(value)"
            }
        }

        return AnyAgentToolValue(string: "Error: \(errorMessage)")
    }

    /// Enhance error with context-specific information
    private func enhanceError(_ error: PeekabooError, for toolName: String) -> ErrorInfo {
        // Enhance error with context-specific information
        var message = error.localizedDescription
        var suggestion: String?
        var metadata: [String: String] = [:]

        switch error {
        case .permissionDeniedScreenRecording:
            suggestion = "Grant Screen Recording permission in System Settings → Privacy & Security → Screen Recording"
            metadata["required_permission"] = "Screen Recording"

        case .permissionDeniedAccessibility:
            suggestion = "Grant Accessibility permission in System Settings → Privacy & Security → Accessibility"
            metadata["required_permission"] = "Accessibility"

        case .permissionDeniedEventSynthesizing:
            suggestion = "Grant event-synthesizing access in System Settings → Privacy & Security → Accessibility"
            metadata["required_permission"] = "Event Synthesizing"

        case let .appNotFound(appName):
            message = "Application '\(appName)' not found"
            suggestion = "Check the app name spelling or use the app tool with action 'list'"
            metadata["app_name"] = appName

        case let .windowNotFound(criteria):
            if let criteria {
                message = "No window found matching: \(criteria)"
                metadata["criteria"] = criteria
            } else {
                message = "No window found"
            }
            suggestion = "Use the window tool with action 'list', or check if the app is running"

        case let .elementNotFound(id):
            message = "Element not found: \(id)"
            suggestion = "Use 'see' to view available elements, or check if the element is visible"
            metadata["element"] = id

        case let .menuNotFound(menu):
            message = "Menu '\(menu)' not found"
            suggestion = "Use 'list_menus' to see available menus, ensure the app is focused"
            metadata["menu"] = menu

        case let .menuItemNotFound(item):
            message = "Menu item '\(item)' not found"
            suggestion = "Check the exact spelling (case-sensitive) or if the item is disabled"
            metadata["item"] = item

        case let .timeout(operation):
            message = "Operation timed out: \(operation)"
            suggestion = "The operation is taking longer than expected. Try again or check if the app is responding"
            metadata["operation"] = operation

        default:
            // Use default error message
            break
        }

        return ErrorInfo(
            message: message,
            suggestion: suggestion,
            metadata: metadata)
    }
}

// MARK: - Supporting Types

private struct ErrorInfo {
    let message: String
    let suggestion: String?
    let metadata: [String: String]
}
