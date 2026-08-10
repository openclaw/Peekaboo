import Foundation

public struct CaptureNoValidFramesError: LocalizedError, Sendable, Equatable {
    public let source: CaptureSessionResult.Source
    public let framesDropped: Int
    public let decodeFailures: Int
    public let firstDecodeError: String?
    public let lastDecodeError: String?
    public let lastCaptureError: String?

    public init(
        source: CaptureSessionResult.Source,
        framesDropped: Int,
        decodeFailures: Int,
        firstDecodeError: String?,
        lastDecodeError: String?,
        lastCaptureError: String?)
    {
        self.source = source
        self.framesDropped = max(0, framesDropped)
        self.decodeFailures = max(0, decodeFailures)
        self.firstDecodeError = CaptureDiagnosticSanitizer.sanitize(firstDecodeError)
        self.lastDecodeError = CaptureDiagnosticSanitizer.sanitize(lastDecodeError)
        self.lastCaptureError = CaptureDiagnosticSanitizer.sanitize(lastCaptureError)
    }

    public var retrySafe: Bool {
        true
    }

    public var errorDescription: String? {
        let message: String
        switch self.source {
        case .live:
            var liveMessage = "Live capture produced no valid frames after \(self.framesDropped) dropped frame(s)."
            if let lastCaptureError {
                liveMessage += " Last capture error: \(lastCaptureError)"
            }
            message = liveMessage
        case .video:
            var videoMessage = "Video capture produced no decodable frames"
            if self.decodeFailures > 0 {
                videoMessage += " after \(self.decodeFailures) decode failure(s)"
            }
            videoMessage += "."
            if let firstDecodeError {
                videoMessage += " First decode error: \(firstDecodeError)"
            }
            if let lastDecodeError, lastDecodeError != firstDecodeError {
                videoMessage += " Last decode error: \(lastDecodeError)"
            }
            message = videoMessage
        }
        return CaptureDiagnosticSanitizer.sanitize(message)
    }
}
