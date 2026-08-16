import AppKit
import CoreGraphics
import Foundation

/// Canonical geometry predicates shared by mutation providers and signed response validation.
public enum WindowMutationGeometryPostcondition {
    public static let canonicalTolerance: CGFloat = 1

    public static func boundsMatch(
        _ actual: CGRect,
        _ expected: CGRect,
        tolerance: CGFloat = Self.canonicalTolerance) -> Bool
    {
        guard tolerance.isFinite, tolerance >= 0 else { return false }
        return abs(actual.minX - expected.minX) <= tolerance &&
            abs(actual.minY - expected.minY) <= tolerance &&
            abs(actual.width - expected.width) <= tolerance &&
            abs(actual.height - expected.height) <= tolerance
    }

    public static func originMatches(
        _ actual: CGPoint,
        _ expected: CGPoint,
        tolerance: CGFloat = Self.canonicalTolerance) -> Bool
    {
        guard tolerance.isFinite, tolerance >= 0 else { return false }
        return abs(actual.x - expected.x) <= tolerance &&
            abs(actual.y - expected.y) <= tolerance
    }

    public static func sizeMatches(
        _ actual: CGSize,
        _ expected: CGSize,
        tolerance: CGFloat = Self.canonicalTolerance) -> Bool
    {
        guard tolerance.isFinite, tolerance >= 0 else { return false }
        return abs(actual.width - expected.width) <= tolerance &&
            abs(actual.height - expected.height) <= tolerance
    }

    @MainActor
    public static func currentMaximizedVisibleWorkArea(for windowBounds: CGRect) -> CGRect? {
        let primaryDisplayHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main)?.frame.height ?? 0
        let visibleFrames = NSScreen.screens.map { screen in
            CGRect(
                x: screen.visibleFrame.origin.x,
                y: primaryDisplayHeight - screen.visibleFrame.origin.y - screen.visibleFrame.height,
                width: screen.visibleFrame.width,
                height: screen.visibleFrame.height)
        }
        return self.maximizedVisibleWorkArea(
            for: windowBounds,
            screenVisibleWorkAreas: visibleFrames)
    }

    public static func maximizedVisibleWorkArea(
        for windowBounds: CGRect,
        screenVisibleWorkAreas: [CGRect]) -> CGRect?
    {
        guard let greatestOverlap = screenVisibleWorkAreas.max(by: { lhs, rhs in
            lhs.intersection(windowBounds).postconditionArea <
                rhs.intersection(windowBounds).postconditionArea
        }) else {
            return nil
        }
        if greatestOverlap.intersection(windowBounds).postconditionArea > 0 {
            return greatestOverlap
        }

        let center = CGPoint(x: windowBounds.midX, y: windowBounds.midY)
        return screenVisibleWorkAreas.min { lhs, rhs in
            lhs.postconditionCenter.postconditionSquaredDistance(to: center) <
                rhs.postconditionCenter.postconditionSquaredDistance(to: center)
        }
    }
}

/// Server-derived evidence attached only to a mutation response whose postcondition was read back.
public struct WindowMutationPostconditionEvidence: Codable, Equatable, Sendable {
    public let isMaximized: Bool?
    public let verifiedVisibleWorkArea: CGRect?

    public init(
        isMaximized: Bool? = nil,
        verifiedVisibleWorkArea: CGRect? = nil)
    {
        self.isMaximized = isMaximized
        self.verifiedVisibleWorkArea = verifiedVisibleWorkArea
    }
}

extension CGRect {
    fileprivate var postconditionArea: CGFloat {
        self.width * self.height
    }

    fileprivate var postconditionCenter: CGPoint {
        CGPoint(x: self.midX, y: self.midY)
    }
}

extension CGPoint {
    fileprivate func postconditionSquaredDistance(to other: CGPoint) -> CGFloat {
        let dx = self.x - other.x
        let dy = self.y - other.y
        return dx * dx + dy * dy
    }
}
