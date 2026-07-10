import CoreGraphics
import Foundation
import PeekabooCore

// MARK: - Geometry Verification

/// The geometry a window command asked the OS to apply.
///
/// Components the command does not control stay `nil` and are excluded from verification
/// (e.g. `resize` only sets the size, so `origin` is `nil`).
struct WindowGeometryExpectation {
    var origin: CGPoint?
    var size: CGSize?
}

/// Result of comparing the requested geometry with the frame the window actually ended up with.
///
/// AX accepts geometry requests even when the target app clamps them (e.g. a SwiftUI minimum
/// content size), so the only reliable signal is reading the frame back after the operation.
enum WindowGeometryOutcome: Equatable {
    /// The window reached the requested geometry (within tolerance).
    case applied
    /// The window changed, but the OS/app constrained the result (e.g. minimum window size).
    case constrained(warning: String)
    /// The request had no effect at all; the window kept its original frame.
    case ignored(reason: String)
    /// The final frame could not be read back, so the reported bounds may be stale.
    case unverified(warning: String)
}

/// Thrown when a geometry mutation was accepted by AX but the window frame did not change at all.
struct WindowGeometryIgnoredError: Error, LocalizedError {
    let reason: String

    var errorDescription: String? {
        self.reason
    }
}

/// Compare the requested geometry against the frame the window actually settled at.
///
/// `tolerance` absorbs sub-point rounding by the window server; it is intentionally small so
/// real clamping (minimum/maximum sizes, non-resizable windows) is always surfaced.
func evaluateWindowGeometryOutcome(
    action: String,
    requested: WindowGeometryExpectation,
    original: CGRect,
    achieved: CGRect?,
    tolerance: CGFloat = 1.0
) -> WindowGeometryOutcome {
    guard let achieved else {
        return .unverified(
            warning: "Could not read back the window frame after \(action); reported bounds may be stale."
        )
    }

    func matches(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    var unmetDescriptions: [String] = []
    var changedFromOriginal = false
    var requestedAnyChange = false

    if let requestedOrigin = requested.origin {
        let met = matches(achieved.origin.x, requestedOrigin.x) && matches(achieved.origin.y, requestedOrigin.y)
        if !met {
            let requestedText = formatWindowPoint(requestedOrigin)
            let actualText = formatWindowPoint(achieved.origin)
            unmetDescriptions.append("requested position \(requestedText), actual position \(actualText)")
        }
        if !(matches(achieved.origin.x, original.origin.x) && matches(achieved.origin.y, original.origin.y)) {
            changedFromOriginal = true
        }
        if !(matches(requestedOrigin.x, original.origin.x) && matches(requestedOrigin.y, original.origin.y)) {
            requestedAnyChange = true
        }
    }

    if let requestedSize = requested.size {
        let met = matches(achieved.size.width, requestedSize.width) &&
            matches(achieved.size.height, requestedSize.height)
        if !met {
            let requestedText = formatWindowSize(requestedSize)
            let actualText = formatWindowSize(achieved.size)
            unmetDescriptions.append("requested size \(requestedText), actual size \(actualText)")
        }
        if !(matches(achieved.size.width, original.size.width) && matches(achieved.size.height, original.size.height)) {
            changedFromOriginal = true
        }
        if !(matches(requestedSize.width, original.size.width) &&
            matches(requestedSize.height, original.size.height)
        ) {
            requestedAnyChange = true
        }
    }

    if unmetDescriptions.isEmpty {
        return .applied
    }

    let detail = unmetDescriptions.joined(separator: "; ")
    if !changedFromOriginal, requestedAnyChange {
        return .ignored(
            reason: "Window \(action) had no effect: \(detail). " +
                "The app likely enforces a minimum/maximum window size or the window cannot be moved/resized."
        )
    }
    return .constrained(
        warning: "The app constrained the window \(action): \(detail). " +
            "new_bounds reflects the frame the window actually settled at."
    )
}

/// Verification output consumed by the window geometry subcommands.
struct VerifiedWindowActionOutput {
    let windowInfo: ServiceWindowInfo?
    let result: WindowActionResult
    let warning: String?
}

/// Build the action result from the read-back frame, surfacing clamped or unverifiable requests.
///
/// Throws ``WindowGeometryIgnoredError`` when the request changed nothing at all: reporting plain
/// success there would silently lie to scripts and agents that rely on the exit code.
@MainActor
func verifiedWindowActionResult(
    action: String,
    appName: String,
    requested: WindowGeometryExpectation,
    originalInfo: ServiceWindowInfo?,
    refreshedInfo: ServiceWindowInfo?
) throws -> VerifiedWindowActionOutput {
    let finalInfo = refreshedInfo ?? originalInfo
    let outcome: WindowGeometryOutcome = if let originalBounds = originalInfo?.bounds {
        evaluateWindowGeometryOutcome(
            action: action,
            requested: requested,
            original: originalBounds,
            achieved: refreshedInfo?.bounds
        )
    } else {
        .unverified(
            warning: "Could not determine the original window frame; the \(action) result was not verified."
        )
    }

    let warning: String?
    switch outcome {
    case .applied:
        warning = nil
    case let .constrained(text), let .unverified(text):
        warning = text
    case let .ignored(reason):
        throw WindowGeometryIgnoredError(reason: reason)
    }

    let result = createWindowActionResult(
        action: action,
        success: true,
        windowInfo: finalInfo,
        appName: appName,
        requestedBounds: requestedWindowBounds(requested: requested, original: originalInfo?.bounds),
        warning: warning
    )
    return VerifiedWindowActionOutput(windowInfo: finalInfo, result: result, warning: warning)
}

/// Full requested rectangle for the JSON payload; components the command did not set fall back
/// to the pre-operation frame.
private func requestedWindowBounds(requested: WindowGeometryExpectation, original: CGRect?) -> WindowBounds? {
    let origin = requested.origin ?? original?.origin
    let size = requested.size ?? original?.size
    guard let origin, let size else {
        return nil
    }
    return WindowBounds(
        x: Int(origin.x),
        y: Int(origin.y),
        width: Int(size.width),
        height: Int(size.height)
    )
}

func formatWindowPoint(_ point: CGPoint) -> String {
    "(\(Int(point.x)), \(Int(point.y)))"
}

func formatWindowSize(_ size: CGSize) -> String {
    "\(Int(size.width))x\(Int(size.height))"
}
