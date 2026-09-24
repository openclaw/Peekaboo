import CoreGraphics
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooBridge
import PeekabooFoundation

@MainActor
public final class RemoteScreenCaptureService: ScreenCaptureServiceProtocol {
    public let captureTransactionGateOwner: CaptureTransactionGateOwner = .service

    private let client: PeekabooBridgeClient
    private let capturePolicy: RemoteCapturePolicy

    public init(client: PeekabooBridgeClient, capturePolicy: RemoteCapturePolicy = .unrestricted) {
        self.client = client
        self.capturePolicy = capturePolicy
    }

    public func captureScreen(
        displayIndex: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.capturePolicy.requireScreenCaptureKit()
        return try await self.client.captureScreen(
            displayIndex: displayIndex,
            visualizerMode: visualizerMode,
            scale: scale)
    }

    public func captureWindow(
        appIdentifier: String,
        windowIndex: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.capturePolicy.requireScreenCaptureKit()
        return try await self.client.captureWindow(
            appIdentifier: appIdentifier,
            windowIndex: windowIndex,
            visualizerMode: visualizerMode,
            scale: scale)
    }

    public func captureWindow(
        windowID: CGWindowID,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.capturePolicy.requireScreenCaptureKit()
        return try await self.client.captureWindow(windowID: windowID, visualizerMode: visualizerMode, scale: scale)
    }

    public func captureFrontmost(
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.capturePolicy.requireScreenCaptureKit()
        return try await self.client.captureFrontmost(visualizerMode: visualizerMode, scale: scale)
    }

    public func captureArea(
        _ rect: CGRect,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.capturePolicy.requireScreenCaptureKit()
        return try await self.client.captureArea(rect, visualizerMode: visualizerMode, scale: scale)
    }

    public func hasScreenRecordingPermission() async -> Bool {
        do {
            let status = try await self.client.permissionsStatus()
            return status.screenRecording
        } catch {
            return false
        }
    }
}
