import CoreGraphics
import Foundation
import PeekabooAutomationKit

/// Typed request/result validation for the legacy one-image capture family.
///
/// All four operations share one wire response case, so response-family validation alone cannot
/// prove which capture was returned. Keep this binding alongside receipt validation so live signing
/// and offline verification apply the same selector contract.
enum PeekabooBridgeCaptureBinding {
    static func mismatch(
        request: PeekabooBridgeRequest,
        result: CaptureResult,
        requireSelectorResolutionProof: Bool = false) -> String?
    {
        if let mismatch = self.validateScale(request: request, metadata: result.metadata) {
            return mismatch
        }
        let targetMismatch: String? = switch request {
        case let .captureScreen(expected):
            self.validateScreen(expected, metadata: result.metadata)
        case let .captureWindow(expected):
            self.validateWindow(expected, metadata: result.metadata)
        case .captureFrontmost:
            self.validateFrontmost(metadata: result.metadata)
        case let .captureArea(expected):
            self.validateArea(expected, metadata: result.metadata)
        default:
            nil
        }
        if let targetMismatch {
            return targetMismatch
        }
        if let selectorEvidenceMismatch = self.validateWindowSelectorEvidence(
            request: request,
            metadata: result.metadata,
            requireProof: requireSelectorResolutionProof)
        {
            return selectorEvidenceMismatch
        }
        return PeekabooBridgeSelectorResolutionBinding.captureMismatch(
            request: request,
            result: result,
            requireProof: requireSelectorResolutionProof)
    }

    private static func validateScale(
        request: PeekabooBridgeRequest,
        metadata: CaptureMetadata) -> String?
    {
        let expectedScale: CaptureScalePreference? = switch request {
        case let .captureScreen(payload):
            payload.scale
        case let .captureWindow(payload):
            payload.scale
        case let .captureFrontmost(payload):
            payload.scale
        case let .captureArea(payload):
            payload.scale
        default:
            nil
        }
        guard let expectedScale else { return nil }
        guard let diagnostics = metadata.diagnostics else { return "capture diagnostics" }
        guard diagnostics.requestedScale == expectedScale else { return "capture scale" }
        guard diagnostics.finalPixelSize == metadata.size,
              self.isValidSize(diagnostics.finalPixelSize),
              diagnostics.nativeScale.isFinite,
              diagnostics.nativeScale > 0,
              diagnostics.outputScale.isFinite,
              diagnostics.outputScale > 0
        else {
            return "capture raster diagnostics"
        }
        return nil
    }

    private static func validateScreen(
        _ request: PeekabooBridgeCaptureScreenRequest,
        metadata: CaptureMetadata) -> String?
    {
        guard metadata.mode == .screen else { return "screen mode" }
        guard let display = metadata.displayInfo else { return "screen display identity" }
        let expectedIndex = request.displayIndex ?? 0
        guard expectedIndex >= 0, display.index == expectedIndex else {
            return "screen display index"
        }
        guard self.isValidBounds(display.bounds) else { return "screen display bounds" }
        guard metadata.applicationInfo == nil, metadata.windowInfo == nil else {
            return "unexpected screen application or window identity"
        }
        return nil
    }

    private static func validateWindow(
        _ request: PeekabooBridgeCaptureWindowRequest,
        metadata: CaptureMetadata) -> String?
    {
        guard metadata.mode == .window else { return "window mode" }
        guard let application = metadata.applicationInfo,
              let window = metadata.windowInfo,
              self.hasStableWindowIdentity(application: application, window: window)
        else {
            return "window target identity"
        }

        if let expectedWindowID = request.windowId {
            guard request.appIdentifier.isEmpty, request.windowIndex == nil else {
                return "window ID selector carriage"
            }
            guard expectedWindowID > 0, window.windowID == expectedWindowID else {
                return "window ID selector"
            }
            return nil
        }

        let identifier = request.appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              self.application(application, matches: identifier)
        else {
            return "window application selector"
        }
        if let expectedIndex = request.windowIndex {
            guard expectedIndex >= 0, window.index == expectedIndex else {
                return "window index selector"
            }
        }
        return nil
    }

    private static func validateFrontmost(metadata: CaptureMetadata) -> String? {
        guard metadata.mode == .frontmost else { return "frontmost mode" }
        guard let application = metadata.applicationInfo,
              let window = metadata.windowInfo,
              self.hasStableWindowIdentity(application: application, window: window)
        else {
            return "frontmost target identity"
        }
        return nil
    }

    private static func validateWindowSelectorEvidence(
        request: PeekabooBridgeRequest,
        metadata: CaptureMetadata,
        requireProof: Bool) -> String?
    {
        guard requireProof,
              case let .captureWindow(payload) = request,
              payload.windowId == nil,
              let application = metadata.applicationInfo,
              let window = metadata.windowInfo
        else {
            return nil
        }
        guard let applicationProofs = application.selectorResolutionProofs,
              applicationProofs.count == 1,
              let applicationProof = applicationProofs.first,
              applicationProof.scope == .application
        else {
            return "applicationInfo selector proof carriage"
        }
        guard let captureProofs = metadata.selectorResolutionProofs,
              captureProofs.count == 2,
              captureProofs[0] == applicationProof.selecting(windowIdentity: window.mutationIdentity),
              captureProofs[1].scope == .window
        else {
            return "windowInfo selector proof carriage"
        }
        return nil
    }

    private static func validateArea(
        _ request: PeekabooBridgeCaptureAreaRequest,
        metadata: CaptureMetadata) -> String?
    {
        guard self.isValidBounds(request.rect) else { return "area request bounds" }
        guard metadata.mode == .area else { return "area mode" }
        guard let display = metadata.displayInfo,
              display.bounds == request.rect
        else {
            return "area bounds"
        }
        guard metadata.applicationInfo == nil, metadata.windowInfo == nil else {
            return "unexpected area application or window identity"
        }
        return nil
    }

    private static func hasStableWindowIdentity(
        application: ServiceApplicationInfo,
        window: ServiceWindowInfo) -> Bool
    {
        guard let processIdentity = application.processIdentity,
              let windowIdentity = window.mutationIdentity,
              window.windowID > 0,
              self.isValidBounds(window.bounds),
              windowIdentity.windowID == window.windowID,
              windowIdentity.processIdentity == processIdentity,
              windowIdentity.capturedBounds == window.bounds
        else {
            return false
        }
        return true
    }

    private static func application(
        _ application: ServiceApplicationInfo,
        matches identifier: String) -> Bool
    {
        ApplicationIdentifierMatcher.matches(application, identifier: identifier)
    }

    private static func isValidBounds(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite && bounds.origin.y.isFinite &&
            bounds.width.isFinite && bounds.height.isFinite &&
            bounds.width > 0 && bounds.height > 0
    }

    private static func isValidSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
