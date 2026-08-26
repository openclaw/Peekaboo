import Foundation
import PeekabooAutomationKit

/// One internal CDP browser-window observation and the targets Chrome reports inside it.
///
/// Raw CDP identities remain below the browser provider boundary. Public tool results receive
/// opaque page capabilities instead of either of these identifiers.
struct CDPBrowserWindowCandidate: Sendable, Equatable {
    let windowID: BrowserMCPDevToolsWindowID
    let bounds: CGRect
    let titles: Set<String>
    let targetIDs: Set<String>
}

/// Internal proof that one fresh native window receipt names one exact CDP browser window.
struct NativeBrowserWindowCorrelation: Sendable, Equatable {
    let nativeWindowIdentity: WindowMutationIdentity
    let browserWindowID: BrowserMCPDevToolsWindowID
    let browserBounds: CGRect
}

enum NativeBrowserWindowCorrelationError: LocalizedError, Sendable, Equatable {
    case staleNativeWindow
    case noGeometryMatch
    case ambiguousGeometry
    case wrongTargetMembership

    var errorDescription: String? {
        switch self {
        case .staleNativeWindow:
            "The native browser window receipt is stale or lacks exact bounds. Observe the window again."
        case .noGeometryMatch:
            "No CDP browser window matches the fresh native window geometry."
        case .ambiguousGeometry:
            "More than one CDP browser window matches the fresh native window geometry."
        case .wrongTargetMembership:
            "The requested browser target does not belong uniquely to the matched CDP window."
        }
    }
}

enum NativeBrowserWindowCorrelator {
    /// Chrome and WindowServer can differ slightly at frame edges. This fixed tolerance is intentionally
    /// not caller-configurable: widening it would weaken exact-window authorization.
    static let geometryTolerance: CGFloat = 8

    static func correlate(
        expectedNativeWindow: WindowMutationIdentity,
        currentNativeWindow: WindowMutationIdentity?,
        nativeTitle: String?,
        requestedTargetID: String,
        candidates: [CDPBrowserWindowCandidate]) throws -> NativeBrowserWindowCorrelation
    {
        guard let currentNativeWindow,
              self.isValid(currentNativeWindow),
              self.isValid(expectedNativeWindow),
              currentNativeWindow.hasSameStableReceipt(as: expectedNativeWindow),
              let nativeBounds = currentNativeWindow.capturedBounds
        else {
            throw NativeBrowserWindowCorrelationError.staleNativeWindow
        }

        let geometryCandidates = candidates.filter { candidate in
            candidate.windowID.rawValue > 0 &&
                self.isValid(candidate.bounds) &&
                self.matchesGeometry(candidate.bounds, nativeBounds)
        }
        guard !geometryCandidates.isEmpty else {
            throw NativeBrowserWindowCorrelationError.noGeometryMatch
        }

        let selected: CDPBrowserWindowCandidate
        if geometryCandidates.count == 1 {
            selected = geometryCandidates[0]
        } else {
            guard let nativeTitle,
                  !nativeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw NativeBrowserWindowCorrelationError.ambiguousGeometry
            }
            let titleMatches = geometryCandidates.filter { $0.titles.contains(nativeTitle) }
            guard titleMatches.count == 1, let titleMatch = titleMatches.first else {
                throw NativeBrowserWindowCorrelationError.ambiguousGeometry
            }
            selected = titleMatch
        }

        guard !requestedTargetID.isEmpty else {
            throw NativeBrowserWindowCorrelationError.wrongTargetMembership
        }
        let targetWindowIDs = Set(candidates.compactMap { candidate in
            candidate.targetIDs.contains(requestedTargetID) ? candidate.windowID : nil
        })
        guard targetWindowIDs == [selected.windowID] else {
            throw NativeBrowserWindowCorrelationError.wrongTargetMembership
        }

        return NativeBrowserWindowCorrelation(
            nativeWindowIdentity: currentNativeWindow,
            browserWindowID: selected.windowID,
            browserBounds: selected.bounds)
    }

    private static func matchesGeometry(_ browserBounds: CGRect, _ nativeBounds: CGRect) -> Bool {
        abs(browserBounds.origin.x - nativeBounds.origin.x) <= self.geometryTolerance &&
            abs(browserBounds.origin.y - nativeBounds.origin.y) <= self.geometryTolerance &&
            abs(browserBounds.width - nativeBounds.width) <= self.geometryTolerance &&
            abs(browserBounds.height - nativeBounds.height) <= self.geometryTolerance
    }

    private static func isValid(_ identity: WindowMutationIdentity) -> Bool {
        identity.windowID > 0 &&
            identity.ownerProcessIdentifier > 0 &&
            identity.ownerProcessStartIdentity > 0 &&
            identity.capturedBounds.map(self.isValid) == true
    }

    private static func isValid(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite &&
            bounds.origin.y.isFinite &&
            bounds.width.isFinite &&
            bounds.height.isFinite &&
            bounds.width > 0 &&
            bounds.height > 0
    }
}
