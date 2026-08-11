import AppKit
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

extension TypeService {
    @MainActor
    func findAndClickElement(query: String, snapshotId: String?) async throws -> (found: Bool, frame: CGRect?) {
        // Search in snapshot first
        if let snapshotId {
            guard let detectionResult = try? await snapshotManager.getDetectionResult(snapshotId: snapshotId) else {
                throw ActionInputError.staleElement
            }
            if let match = Self.resolveTargetElement(query: query, in: detectionResult) {
                return (true, match.bounds)
            }
            return (false, nil)
        }

        // Fall back to AX search
        if let element = findTextFieldByQuery(query) {
            return (true, element.frame())
        }

        return (false, nil)
    }

    func resolveAdjustedPoint(_ point: CGPoint, snapshotId: String?) async throws -> CGPoint {
        try await WindowMovementTracking.adjustPoint(
            point,
            snapshotId: snapshotId,
            snapshots: self.snapshotManager)
    }

    @MainActor
    static func resolveTargetElement(query: String, in detectionResult: ElementDetectionResult) -> DetectedElement? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryLower = trimmed.lowercased()
        guard !queryLower.isEmpty else { return nil }

        var bestMatch: DetectedElement?
        var bestScore = Int.min

        for element in detectionResult.elements.all where element.isEnabled && !element.isOCRSemanticEvidence {
            let label = element.label?.lowercased()
            let value = element.value?.lowercased()
            let identifier = element.attributes["identifier"]?.lowercased()
            let description = element.attributes["description"]?.lowercased()
            let placeholder = element.attributes["placeholder"]?.lowercased()

            let candidates = [label, value, identifier, description, placeholder].compactMap(\.self)
            guard candidates.contains(where: { $0.contains(queryLower) }) else { continue }

            var score = 0
            if identifier == queryLower {
                score += 400
            }
            if label == queryLower {
                score += 300
            }
            if value == queryLower {
                score += 200
            }

            if identifier?.contains(queryLower) == true {
                score += 200
            }
            if label?.contains(queryLower) == true {
                score += 150
            }
            if value?.contains(queryLower) == true {
                score += 100
            }
            if description?.contains(queryLower) == true {
                score += 60
            }
            if placeholder?.contains(queryLower) == true {
                score += 40
            }

            if element.type == .textField {
                score += 25
            }

            if score > bestScore {
                bestScore = score
                bestMatch = element
            } else if score == bestScore, let currentBest = bestMatch {
                // Deterministic tie-break: prefer lower (smaller y) matches.
                // This helps when SwiftUI reports multiple nodes with the same identifier.
                if element.bounds.origin.y < currentBest.bounds.origin.y {
                    bestMatch = element
                }
            }
        }

        return bestMatch
    }

    @MainActor
    private func findTextFieldByQuery(_ query: String) -> Element? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXApp(frontApp).element

        return self.searchTextFields(in: appElement, matching: query.lowercased())
    }

    @MainActor
    private func searchTextFields(in element: Element, matching query: String) -> Element? {
        let role = element.role()?.lowercased() ?? ""

        // Check if this is a text field
        if role.contains("textfield") || role.contains("textarea") || role.contains("searchfield") {
            let title = element.title()?.lowercased() ?? ""
            let label = element.label()?.lowercased() ?? ""
            let placeholder = element.placeholderValue()?.lowercased() ?? ""

            if title.contains(query) || label.contains(query) || placeholder.contains(query) {
                return element
            }
        }

        // Search children
        if let children = element.children() {
            for child in children {
                if let found = searchTextFields(in: child, matching: query) {
                    return found
                }
            }
        }

        return nil
    }
}
