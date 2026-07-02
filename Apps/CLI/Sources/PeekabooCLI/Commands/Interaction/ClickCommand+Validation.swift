import Commander
import CoreGraphics
import Foundation
import PeekabooCore

extension ClickCommand {
    mutating func validate() throws {
        try self.target.validate()
        guard self.query != nil || self.on != nil || self.id != nil || self.coords != nil else {
            throw ValidationError("Specify an element query, --on/--id, or --coords.")
        }

        if self.on != nil && self.coords != nil {
            throw ValidationError("Cannot specify both --on and --coords.")
        }

        if self.on != nil && self.id != nil {
            throw ValidationError("Cannot specify both --on and --id.")
        }

        if let coordString = self.coords, Self.parseCoordinates(coordString) == nil {
            throw ValidationError("Invalid coordinates format. Use: x,y")
        }

        if self.globalCoords && self.coords == nil {
            throw ValidationError("--global-coords requires --coords")
        }

        if self.foreground && self.focusOptions.backgroundDeliveryExplicitlyRequested {
            throw ValidationError("--foreground cannot be combined with --focus-background")
        }

        if self.focusOptions.backgroundDeliveryExplicitlyRequested &&
            self.focusOptions.hasForegroundFocusOverrides {
            throw ValidationError("--focus-background cannot be combined with focus options")
        }
    }

    func formatElementInfo(_ element: DetectedElement) -> String {
        let roleDescription = element.type.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        let label = element.label ?? element.value ?? element.id
        return "\(roleDescription): \(label)"
    }

    static func elementNotFoundMessage(_ elementId: String) -> String {
        """
        Element with ID '\(elementId)' not found

        💡 Hints:
          • Run 'peekaboo see' first to capture UI elements
          • Copy the opaque element ID exactly from current see or inspect-ui output
          • Element may have disappeared or changed
        """
    }

    static func queryNotFoundMessage(_ query: String, waitFor: Int) -> String {
        """
        No actionable element found matching '\(query)' after \(waitFor)ms

        💡 Hints:
          • Menu bar items often require clicking on their icon coordinates
          • Try 'peekaboo see' first to get element IDs
          • Use partial text matching (case-insensitive)
          • Element might be disabled or not visible
          • Try increasing --wait-for timeout
        """
    }

    /// Parse coordinates string (e.g., "100,200") into CGPoint.
    static func parseCoordinates(_ coords: String) -> CGPoint? {
        let parts = coords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]) else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    /// Create element locator from query string.
    static func createLocatorFromQuery(_ query: String) -> (type: String, value: String) {
        if query.hasPrefix("#") {
            ("id", String(query.dropFirst()))
        } else if query.hasPrefix(".") {
            ("class", String(query.dropFirst()))
        } else if query.hasPrefix("//") || query.hasPrefix("/") {
            ("xpath", query)
        } else {
            ("text", query)
        }
    }
}
