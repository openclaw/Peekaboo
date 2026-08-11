import CoreGraphics
import Foundation
import PeekabooFoundation
@preconcurrency import ScreenCaptureKit

#if !PEEKABOO_DISABLE_PRIVATE_SCK_WINDOW_LOOKUP
import ObjectiveC
#endif

@_spi(Testing) public enum PrivateScreenCaptureKitWindowLookupPolicy {
    public nonisolated static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        #if PEEKABOO_DISABLE_PRIVATE_SCK_WINDOW_LOOKUP
        return false
        #else
        if self.envFlagIsEnabled(environment["PEEKABOO_DISABLE_PRIVATE_SCK_WINDOW_LOOKUP"]) {
            return false
        }
        if let value = environment["PEEKABOO_USE_PRIVATE_SCK_WINDOW_LOOKUP"] {
            return self.envFlagIsEnabled(value)
        }
        return true
        #endif
    }

    public nonisolated static func allowsSystemFallback(
        after error: any Error,
        laneIsQuarantined: Bool) -> Bool
    {
        guard !laneIsQuarantined, !(error is CancellationError) else { return false }
        return (error as? PeekabooError)?.code != .timeout
    }

    private nonisolated static func envFlagIsEnabled(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        default:
            return false
        }
    }
}

extension LegacyScreenCaptureOperator {
    nonisolated static func privateScreenCaptureKitWindowLookupEnabled() -> Bool {
        PrivateScreenCaptureKitWindowLookupPolicy.isEnabled()
    }

    func captureWindowWithPrivateScreenCaptureKit(
        windowID: CGWindowID,
        correlationId: String,
        scale: CaptureScalePreference) async throws -> CGImage
    {
        #if PEEKABOO_DISABLE_PRIVATE_SCK_WINDOW_LOOKUP
        throw OperationError.captureFailed(
            reason: "Private ScreenCaptureKit window lookup disabled at compile time")
        #else
        // The caller already excludes explicit classic requests. Keep the same guard at this
        // SCK leaf so a future direct caller cannot make classic claim process ownership.
        guard ScreenCaptureService.captureEnginePreference != .legacy else {
            throw OperationError.captureFailed(
                reason: "Private ScreenCaptureKit window lookup is disabled for explicit classic capture")
        }
        let scWindow = try await self.fetchWindowWithPrivateScreenCaptureKit(windowID: windowID)
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = self.makeScreenshotConfiguration()
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true
        if #available(macOS 14.2, *) {
            config.includeChildWindows = false
        }
        let pixelSize = ScreenCapturePlanner.desktopIndependentWindowPixelSize(
            filterContentRect: filter.contentRect,
            fallbackWindowFrame: scWindow.frame,
            pointPixelScale: CGFloat(filter.pointPixelScale),
            fallbackNativeScale: 1,
            useNativeScale: scale == .native)
        config.width = pixelSize.width
        config.height = pixelSize.height

        self.logger.debug(
            "Capturing window via private ScreenCaptureKit window-id lookup",
            metadata: [
                "windowID": String(windowID),
                "windowFrame": "\(scWindow.frame)",
            ],
            correlationId: correlationId)

        let image = try await ScreenCaptureKitCaptureGate.captureImage(
            contentFilter: filter,
            configuration: config)
        guard ScreenCapturePlanner.matchesExpectedWindowPixelSize(
            imageWidth: image.width,
            imageHeight: image.height,
            expected: pixelSize)
        else {
            throw OperationError.captureFailed(
                reason: "Private ScreenCaptureKit returned \(image.width)x\(image.height) for a " +
                    "\(pixelSize.width)x\(pixelSize.height) window capture")
        }
        return image
        #endif
    }

    #if !PEEKABOO_DISABLE_PRIVATE_SCK_WINDOW_LOOKUP
    private func fetchWindowWithPrivateScreenCaptureKit(windowID: CGWindowID) async throws -> SCWindow {
        guard let privateWindowID = UInt32(exactly: windowID) else {
            throw OperationError.captureFailed(reason: "Window ID \(windowID) is outside UInt32 range")
        }

        let selector = NSSelectorFromString("fetchWindowForWindowID:withCompletionHandler:")
        guard let method = class_getClassMethod(SCShareableContent.self, selector) else {
            throw OperationError.captureFailed(
                reason: "Private SCShareableContent.fetchWindowForWindowID selector is unavailable")
        }

        let implementation = method_getImplementation(method)
        typealias Completion = @convention(block) (AnyObject?) -> Void
        typealias FetchWindow = @convention(c) (AnyClass, Selector, UInt32, Completion) -> Void
        let fetchWindow = unsafeBitCast(implementation, to: FetchWindow.self)

        // Private API, intentionally isolated: Hopper shows `/usr/sbin/screencapture -l` resolving a
        // WindowServer ID through `SCShareableContent` before building a desktop-independent window filter.
        // Public `SCShareableContent.windows` enumeration can miss windows that this lookup still captures.
        // If Apple removes this selector, callers fall back to `/usr/sbin/screencapture -l` and then public SCK.
        return try await ScreenCaptureKitCaptureGate.runOwnedOperation(
            seconds: 1.0,
            operationName: "SCShareableContent.fetchWindowForWindowID")
        {
            try await ScreenCaptureKitCallbackBridge<SCWindow>.wait { finish in
                let completion: Completion = { object in
                    guard let window = object as? SCWindow else {
                        finish(.failure(OperationError.captureFailed(
                            reason: "Private SCShareableContent lookup did not return window \(windowID)")))
                        return
                    }
                    finish(.success(window))
                }
                fetchWindow(SCShareableContent.self, selector, privateWindowID, completion)
            }
        }
    }
    #endif
}
