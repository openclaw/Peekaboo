import Commander
import CoreGraphics
import Foundation
import PeekabooCore

struct ImageWindowObservationTarget {
    let target: DesktopObservationTargetRequest
    let focusIdentifier: String
    let preferredName: String
}

@MainActor
extension SeeCommand {
    func observationWindowSelection() throws -> WindowSelection {
        try self.validateInteractionTargetSelectors()
        if let windowTitle {
            return .title(windowTitle)
        }
        if let windowIndex {
            return .index(windowIndex)
        }
        return .automatic
    }

    func observationApplicationTargetForWindowCapture(
        selection: WindowSelection? = nil
    ) throws -> ImageWindowObservationTarget {
        try self.validateInteractionTargetSelectors()
        let resolvedSelection = try selection ?? self.observationWindowSelection()
        if let pid = try self.resolveExplicitPIDObservationTarget() {
            let identifier = "PID:\(pid)"
            return ImageWindowObservationTarget(
                target: .pid(pid, window: resolvedSelection),
                focusIdentifier: identifier,
                preferredName: identifier
            )
        }

        let identifier = try self.resolveApplicationIdentifier()
        return ImageWindowObservationTarget(
            target: .app(identifier: identifier, window: resolvedSelection),
            focusIdentifier: identifier,
            preferredName: identifier
        )
    }

    func observationTargetForExactWindowCapture(_ windowID: Int) throws -> DesktopObservationTargetRequest {
        try self.validateInteractionTargetSelectors()
        let selection = WindowSelection.id(CGWindowID(windowID))
        if self.app != nil || self.pid != nil {
            return try self.observationApplicationTargetForWindowCapture(selection: selection).target
        }
        return .windowID(CGWindowID(windowID))
    }

    func makePixelObservationRequest(
        target: DesktopObservationTargetRequest,
        outputURL: URL,
        snapshotID: String? = nil
    ) -> DesktopObservationRequest {
        DesktopObservationRequest(
            target: target,
            capture: DesktopCaptureOptions(
                engine: self.pixelObservationCaptureEnginePreference,
                scale: self.captureScale,
                focus: self.captureFocus,
                visualizerMode: .resolved(for: self.captureFocus, visibleMode: .screenshotFlash)
            ),
            detection: DesktopDetectionOptions(mode: .none),
            output: DesktopObservationOutputOptions(
                path: outputURL.path,
                format: self.format,
                saveRawScreenshot: true,
                saveSnapshot: snapshotID != nil,
                snapshotID: snapshotID
            )
        )
    }

    private var captureScale: CaptureScalePreference {
        self.retina ? .native : .logical1x
    }

    private var pixelObservationCaptureEnginePreference: CaptureEnginePreference {
        if let safetyOverride = self.runtime?.captureEngineSafetyOverride {
            return safetyOverride
        }
        return ObservationCommandSupport.captureEnginePreference(
            cliValue: self.captureEngine,
            configuredValue: self.configuredCaptureEnginePreference
        )
    }
}
