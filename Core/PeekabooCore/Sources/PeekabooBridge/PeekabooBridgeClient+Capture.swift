import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    public func captureScreen(
        displayIndex: Int?,
        visualizerMode: CaptureVisualizerMode = .none,
        scale: CaptureScalePreference = .logical1x) async throws -> CaptureResult
    {
        let payload = PeekabooBridgeCaptureScreenRequest(
            displayIndex: displayIndex,
            visualizerMode: visualizerMode,
            scale: scale)
        let response = try await self.send(.captureScreen(payload))
        return try Self.unwrapCapture(from: response)
    }

    public func captureWindow(
        appIdentifier: String,
        windowIndex: Int?,
        visualizerMode: CaptureVisualizerMode = .none,
        scale: CaptureScalePreference = .logical1x) async throws -> CaptureResult
    {
        let payload = PeekabooBridgeCaptureWindowRequest(
            appIdentifier: appIdentifier,
            windowIndex: windowIndex,
            windowId: nil,
            visualizerMode: visualizerMode,
            scale: scale)
        let response = try await self.send(.captureWindow(payload))
        return try Self.unwrapCapture(from: response)
    }

    public func captureWindow(
        windowID: CGWindowID,
        visualizerMode: CaptureVisualizerMode = .none,
        scale: CaptureScalePreference = .logical1x) async throws -> CaptureResult
    {
        let payload = PeekabooBridgeCaptureWindowRequest(
            appIdentifier: "",
            windowIndex: nil,
            windowId: Int(windowID),
            visualizerMode: visualizerMode,
            scale: scale)
        let response = try await self.send(.captureWindow(payload))
        return try Self.unwrapCapture(from: response)
    }

    public func captureFrontmost(
        visualizerMode: CaptureVisualizerMode = .none,
        scale: CaptureScalePreference = .logical1x) async throws -> CaptureResult
    {
        let payload = PeekabooBridgeCaptureFrontmostRequest(visualizerMode: visualizerMode, scale: scale)
        let response = try await self.send(.captureFrontmost(payload))
        return try Self.unwrapCapture(from: response)
    }

    public func captureArea(
        _ rect: CGRect,
        visualizerMode: CaptureVisualizerMode = .none,
        scale: CaptureScalePreference = .logical1x) async throws -> CaptureResult
    {
        let payload = PeekabooBridgeCaptureAreaRequest(rect: rect, visualizerMode: visualizerMode, scale: scale)
        let response = try await self.send(.captureArea(payload))
        return try Self.unwrapCapture(from: response)
    }

    public func detectElements(
        in imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?,
        requestTimeoutSec: TimeInterval? = nil) async throws -> ElementDetectionResult
    {
        try await self.detectElementsWithOutcome(
            in: imageData,
            snapshotId: snapshotId,
            windowContext: windowContext,
            requestTimeoutSec: requestTimeoutSec).payload
    }

    public func detectElementsWithOutcome(
        in imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?,
        requestTimeoutSec: TimeInterval? = nil) async throws -> UIAutomationActionResult<ElementDetectionResult>
    {
        let payload = PeekabooBridgeDetectElementsRequest(
            imageData: imageData,
            snapshotId: snapshotId,
            windowContext: windowContext)
        return try await self.actionResult(
            for: .detectElements(payload),
            expectedResponse: "detectElements",
            timeoutSec: requestTimeoutSec)
        { response in
            guard case let .elementDetection(result) = response else { return nil }
            return result
        }
    }

    public func inspectAccessibilityTree(
        windowContext: WindowContext?,
        requestTimeoutSec: TimeInterval? = nil) async throws -> ElementDetectionResult
    {
        try await self.inspectAccessibilityTreeWithOutcome(
            windowContext: windowContext,
            requestTimeoutSec: requestTimeoutSec).payload
    }

    public func inspectAccessibilityTreeWithOutcome(
        windowContext: WindowContext?,
        requestTimeoutSec: TimeInterval? = nil) async throws -> UIAutomationActionResult<ElementDetectionResult>
    {
        let payload = PeekabooBridgeInspectAccessibilityTreeRequest(windowContext: windowContext)
        return try await self.actionResult(
            for: .inspectAccessibilityTree(payload),
            expectedResponse: "inspectAccessibilityTree",
            timeoutSec: requestTimeoutSec)
        { response in
            guard case let .elementDetection(result) = response else { return nil }
            return result
        }
    }

    private static func unwrapCapture(from response: PeekabooBridgeResponse) throws -> CaptureResult {
        switch response {
        case let .capture(result):
            return result
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected capture response")
        }
    }
}
