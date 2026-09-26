import CoreGraphics
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooBridge
import PeekabooFoundation

@MainActor
public final class RemoteScreenCaptureService: EngineAwareScreenCaptureServiceProtocol {
    public let captureTransactionGateOwner: CaptureTransactionGateOwner = .service

    let unscopedCapture: any ScreenCaptureServiceProtocol
    private let desktopObservation: RemoteDesktopObservationService
    @TaskLocal private static var captureEnginePreference: CaptureEnginePreference?

    public convenience init(client: PeekabooBridgeClient, capturePolicy: RemoteCapturePolicy = .unrestricted) {
        self.init(
            client: client,
            capturePolicy: capturePolicy,
            desktopObservation: RemoteDesktopObservationService(client: client, capturePolicy: capturePolicy))
    }

    init(
        client: PeekabooBridgeClient,
        capturePolicy: RemoteCapturePolicy = .unrestricted,
        desktopObservation: RemoteDesktopObservationService)
    {
        self.unscopedCapture = RawRemoteScreenCaptureService(client: client, capturePolicy: capturePolicy)
        self.desktopObservation = desktopObservation
    }

    public func withCaptureEngine<T: Sendable>(
        _ engine: CaptureEnginePreference,
        operation: @MainActor () async throws -> T) async rethrows -> T
    {
        try await Self.$captureEnginePreference.withValue(engine, operation: operation)
    }

    public func captureScreen(
        displayIndex: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        if let engine = Self.captureEnginePreference {
            return try await self.capture(
                .screen(index: displayIndex), engine: engine, visualizerMode: visualizerMode, scale: scale)
        }
        return try await self.unscopedCapture.captureScreen(
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
        if let engine = Self.captureEnginePreference {
            return try await self.capture(
                .app(identifier: appIdentifier, window: windowIndex.map(WindowSelection.index)),
                engine: engine,
                visualizerMode: visualizerMode,
                scale: scale)
        }
        return try await self.unscopedCapture.captureWindow(
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
        if let engine = Self.captureEnginePreference {
            return try await self.capture(
                .windowID(windowID), engine: engine, visualizerMode: visualizerMode, scale: scale)
        }
        return try await self.unscopedCapture.captureWindow(
            windowID: windowID, visualizerMode: visualizerMode, scale: scale)
    }

    public func captureFrontmost(
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        if let engine = Self.captureEnginePreference {
            return try await self.capture(.frontmost, engine: engine, visualizerMode: visualizerMode, scale: scale)
        }
        return try await self.unscopedCapture.captureFrontmost(visualizerMode: visualizerMode, scale: scale)
    }

    public func captureArea(
        _ rect: CGRect,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        if let engine = Self.captureEnginePreference {
            return try await self.capture(.area(rect), engine: engine, visualizerMode: visualizerMode, scale: scale)
        }
        return try await self.unscopedCapture.captureArea(rect, visualizerMode: visualizerMode, scale: scale)
    }

    public func hasScreenRecordingPermission() async -> Bool {
        await self.unscopedCapture.hasScreenRecordingPermission()
    }

    private func capture(
        _ target: DesktopObservationTargetRequest,
        engine: CaptureEnginePreference,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        try await self.desktopObservation.observe(DesktopObservationRequest(
            target: target,
            capture: DesktopCaptureOptions(engine: engine, scale: scale, visualizerMode: visualizerMode),
            detection: DesktopDetectionOptions(mode: .none),
            output: DesktopObservationOutputOptions(includeImageData: true)))
            .capture
    }
}

/// Legacy observation hosts use raw capture RPCs and cannot consume even an explicit `auto` engine scope.
@MainActor
private final class RawRemoteScreenCaptureService: ScreenCaptureServiceProtocol {
    let captureTransactionGateOwner: CaptureTransactionGateOwner = .service
    private let client: PeekabooBridgeClient
    private let capturePolicy: RemoteCapturePolicy

    init(client: PeekabooBridgeClient, capturePolicy: RemoteCapturePolicy) {
        self.client = client
        self.capturePolicy = capturePolicy
    }

    func captureScreen(
        displayIndex: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.capturePolicy.requireScreenCaptureKit()
        return try await self.client.captureScreen(
            displayIndex: displayIndex, visualizerMode: visualizerMode, scale: scale)
    }

    func captureWindow(
        appIdentifier: String,
        windowIndex: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.capturePolicy.requireScreenCaptureKit()
        return try await self.client.captureWindow(
            appIdentifier: appIdentifier, windowIndex: windowIndex, visualizerMode: visualizerMode, scale: scale)
    }

    func captureWindow(
        windowID: CGWindowID,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.capturePolicy.requireScreenCaptureKit()
        return try await self.client.captureWindow(windowID: windowID, visualizerMode: visualizerMode, scale: scale)
    }

    func captureFrontmost(
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.capturePolicy.requireScreenCaptureKit()
        return try await self.client.captureFrontmost(visualizerMode: visualizerMode, scale: scale)
    }

    func captureArea(
        _ rect: CGRect,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.capturePolicy.requireScreenCaptureKit()
        return try await self.client.captureArea(rect, visualizerMode: visualizerMode, scale: scale)
    }

    func hasScreenRecordingPermission() async -> Bool {
        do {
            let status = try await self.client.permissionsStatus()
            return status.screenRecording
        } catch {
            return false
        }
    }
}
