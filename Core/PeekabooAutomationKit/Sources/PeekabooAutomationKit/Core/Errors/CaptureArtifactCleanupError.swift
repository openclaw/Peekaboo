import Foundation

public struct CaptureArtifactCleanupError: LocalizedError {
    public let primaryError: any Error
    public let cleanupError: any Error
    public let artifactPath: String

    public init(primaryError: any Error, cleanupError: any Error, artifactPath: String) {
        self.primaryError = primaryError
        self.cleanupError = cleanupError
        self.artifactPath = artifactPath
    }

    public var errorDescription: String? {
        let primary = CaptureDiagnosticSanitizer.sanitize(
            self.primaryError.localizedDescription,
            maximumUTF8Bytes: 180) ??
            "Capture failed"
        let path = CaptureDiagnosticSanitizer.sanitize(
            self.artifactPath,
            maximumUTF8Bytes: 96) ?? "<unknown path>"
        let cleanup = CaptureDiagnosticSanitizer.sanitize(
            self.cleanupError.localizedDescription,
            maximumUTF8Bytes: 160) ??
            "cleanup failed"
        return CaptureDiagnosticSanitizer.sanitize(
            "Primary capture error: \(primary). Incomplete video cleanup failed at \(path): \(cleanup)")
    }
}
