import Commander
import CoreGraphics
import Foundation
import PeekabooCore

extension ClickCommand: PreRuntimeValidatingCommand {
    func validateBeforeRuntime() throws {
        var command = self
        try command.validate()
    }

    mutating func validate() throws {
        try self.target.validate()
        self.query = Self.nonEmptyClickSelector(self.query)
        self.on = Self.nonEmptyClickSelector(self.on)
        self.at = Self.nonEmptyClickSelector(self.at)
        let targetCount = [self.query, self.on, self.at].compactMap(\.self).count
        guard targetCount > 0 else {
            throw ValidationError("Specify an element query, --on, or --at.")
        }
        guard targetCount == 1 else {
            throw ValidationError("Specify exactly one click target: element query, --on, or --at.")
        }

        if let coordString = self.at, Self.parseCoordinates(coordString) == nil {
            throw Self.invalidCoordinatesRefusal
        }

        if self.global && self.at == nil {
            throw ValidationError("--global requires --at")
        }

        if self.focusOptions.foreground && self.focusOptions.backgroundDeliveryExplicitlyRequested {
            throw ValidationError("--foreground cannot be combined with --focus-background")
        }

        let selectedVariants = [self.double, self.right, self.middle, self.triple, self.longPress]
            .filter(\.self).count
        if selectedVariants > 1 {
            throw ValidationError(
                "Click variants are mutually exclusive; use only one of --double, --right, --middle, " +
                    "--triple, or --long-press"
            )
        }

        if self.longPress && !self.focusOptions.foreground {
            throw ValidationError(
                "--long-press uses the shared physical cursor and requires explicit --foreground consent"
            )
        }

        if self.focusOptions.backgroundDeliveryExplicitlyRequested &&
            self.focusOptions.hasForegroundFocusOverrides {
            throw ValidationError("--focus-background cannot be combined with focus options")
        }

        if !self.focusOptions.foreground, self.focusOptions.hasForegroundFocusOverrides {
            throw ValidationError("Focus options require --foreground for click")
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
          • Copy the opaque element ID exactly from current see output
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

    private static func nonEmptyClickSelector(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
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
