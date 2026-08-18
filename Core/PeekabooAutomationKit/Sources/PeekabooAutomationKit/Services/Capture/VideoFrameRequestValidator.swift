import Foundation
import PeekabooFoundation

/// Synchronous request validation shared by CLI/MCP admission and the video frame source.
public enum VideoFrameRequestValidator {
    public static func validate(
        sampleFps: Double?,
        everyMs: Int?,
        startMs: Int?,
        endMs: Int?,
        resolutionCap: Double?) throws
    {
        if let sampleFps, !sampleFps.isFinite || sampleFps <= 0 {
            throw PeekabooError.invalidInput("sample-fps must be a positive finite value")
        }
        if let everyMs, everyMs <= 0 {
            throw PeekabooError.invalidInput("every-ms must be greater than zero")
        }
        if let startMs, startMs < 0 {
            throw PeekabooError.invalidInput("start-ms must be zero or greater")
        }
        if let endMs, endMs < 0 {
            throw PeekabooError.invalidInput("end-ms must be zero or greater")
        }
        if let endMs, endMs <= (startMs ?? 0) {
            throw PeekabooError.invalidInput("end-ms must exceed start-ms")
        }
        if let resolutionCap, !resolutionCap.isFinite || resolutionCap <= 0 {
            throw PeekabooError.invalidInput("resolution-cap must be a positive finite value")
        }
    }
}
