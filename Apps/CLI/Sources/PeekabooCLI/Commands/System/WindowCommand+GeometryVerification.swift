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

// MARK: - Frame Settling

/// Result of polling a window's frame until it stops changing.
struct SettledWindowFrame {
    let info: ServiceWindowInfo?
    /// `true` when two consecutive reads agreed within tolerance before the attempt budget ran out.
    let stabilized: Bool
}

/// Whether two rectangles match within `tolerance` on every edge.
func windowFramesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) <= tolerance &&
        abs(lhs.origin.y - rhs.origin.y) <= tolerance &&
        abs(lhs.size.width - rhs.size.width) <= tolerance &&
        abs(lhs.size.height - rhs.size.height) <= tolerance
}

/// Poll a window's frame until it is stable across two consecutive reads or the attempt budget is spent.
///
/// Animated window operations (notably `maximize`, which presses the green zoom button) report an
/// intermediate frame if read immediately, so callers that need the *settled* frame must wait for the
/// animation to finish. Synchronous AX geometry setters (`resize`/`move`/`set-bounds`) do not animate
/// and therefore do not need this.
@MainActor
func settleWindowFrame(
    tolerance: CGFloat = 1.0,
    maxAttempts: Int = 24,
    pollInterval: Duration = .milliseconds(50),
    read: () async -> ServiceWindowInfo?
) async -> SettledWindowFrame {
    var previous = await read()
    var attempts = 1
    while attempts < maxAttempts {
        if pollInterval > .zero {
            try? await Task.sleep(for: pollInterval)
        }
        let current = await read()
        attempts += 1
        if let previousBounds = previous?.bounds, let currentBounds = current?.bounds,
           windowFramesMatch(previousBounds, currentBounds, tolerance: tolerance) {
            return SettledWindowFrame(info: current, stabilized: true)
        }
        previous = current ?? previous
    }
    return SettledWindowFrame(info: previous, stabilized: false)
}

// MARK: - Idempotent Maximize

/// Whether the window's size matches any screen's visible-frame size within `tolerance`.
///
/// A window whose size equals its screen's visible frame is already maximized. This compares sizes
/// only, never origins, so it is independent of AppKit/CoreGraphics coordinate-origin differences.
/// AX window sizes and `NSScreen.visibleFrame` are both in points, so the comparison is
/// Convert an AppKit screen frame (bottom-left origin, y-up) into the global top-left coordinate
/// space (y-down) used by AX/CoreGraphics window bounds.
///
/// AX window positions and AppKit `NSScreen` frames both use points but opposite vertical origins,
/// so a maximized window can only be recognized by first flipping the screen frame using the primary
/// display's height (the primary display is the one whose AppKit origin is `.zero`).
func convertAppKitFrameToTopLeft(_ frame: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
    CGRect(
        x: frame.origin.x,
        y: primaryDisplayHeight - frame.origin.y - frame.height,
        width: frame.width,
        height: frame.height
    )
}

/// Whether the window's frame matches any screen's visible frame on both origin and size.
///
/// A full-rectangle match (not size-only) is required so a screen-sized window that has been moved
/// or pushed partly off-screen is *not* treated as maximized. `screenVisibleFramesTopLeft` must
/// already be in the same top-left coordinate space as `bounds` (see `convertAppKitFrameToTopLeft`).
/// The match is deliberately conservative: if the app's zoom target differs from the visible frame
/// (so nothing matches), `maximize` simply presses zoom instead of skipping — it never skips a real
/// request.
func windowMatchesAnyScreen(
    bounds: CGRect,
    screenVisibleFramesTopLeft: [CGRect],
    tolerance: CGFloat = 4.0
) -> Bool {
    screenVisibleFramesTopLeft.contains { windowFramesMatch(bounds, $0, tolerance: tolerance) }
}

/// Outcome of an idempotent maximize: the settled frame plus whether the window was already maximized.
struct MaximizeOutcome {
    let info: ServiceWindowInfo?
    /// `true` when the window already filled its screen, so the (toggling) zoom press was skipped.
    let alreadyMaximized: Bool
    /// `false` when the frame never stopped changing within the poll budget.
    let stabilized: Bool
}

/// Maximize a window idempotently.
///
/// AppKit's green zoom button is a toggle: pressing it on an already-maximized window would restore
/// the smaller user frame. So if the window already occupies a screen's visible frame (matched on
/// origin and size), this no-ops and reports the current frame. Otherwise it presses zoom and waits
/// for the animated frame to settle before reporting, so `new_bounds` is the settled frame rather
/// than a mid-animation one.
///
/// `press` performs the underlying (animated) maximize; `read` returns the current frame. Both are
/// injected so the flow can be exercised without a live window server.
@MainActor
func resolveIdempotentMaximize(
    original: ServiceWindowInfo?,
    screenVisibleFramesTopLeft: [CGRect],
    tolerance: CGFloat = 1.0,
    screenMatchTolerance: CGFloat = 4.0,
    maxAttempts: Int = 24,
    pollInterval: Duration = .milliseconds(50),
    press: () async throws -> Void,
    read: () async -> ServiceWindowInfo?
) async throws -> MaximizeOutcome {
    // Idempotency: an already-maximized window stays maximized; pressing the toggle would shrink it.
    if let originalBounds = original?.bounds,
       windowMatchesAnyScreen(
           bounds: originalBounds,
           screenVisibleFramesTopLeft: screenVisibleFramesTopLeft,
           tolerance: screenMatchTolerance
       ) {
        return MaximizeOutcome(info: original, alreadyMaximized: true, stabilized: true)
    }

    try await press()
    let settled = await settleWindowFrame(
        tolerance: tolerance,
        maxAttempts: maxAttempts,
        pollInterval: pollInterval,
        read: read
    )
    return MaximizeOutcome(info: settled.info, alreadyMaximized: false, stabilized: settled.stabilized)
}
