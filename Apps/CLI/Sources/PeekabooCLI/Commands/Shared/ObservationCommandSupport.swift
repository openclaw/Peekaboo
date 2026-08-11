import Foundation
import PeekabooCore

enum ObservationCommandSupport {
    private static let supportedCaptureEngineValues: Set<String> = [
        "auto",
        "modern", "modern-only", "sckit", "sc", "screen-capture-kit", "sck",
        "classic", "cg", "legacy", "legacy-only", "false", "0", "no",
    ]

    static func isSupportedCaptureEngineValue(_ value: String) -> Bool {
        self.supportedCaptureEngineValues.contains(
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    static func captureEnginePreference(cliValue: String?, configuredValue: String?) -> CaptureEnginePreference {
        let value = (cliValue ?? configuredValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch value {
        case "modern", "modern-only", "sckit", "sc", "screen-capture-kit", "sck":
            return .modern
        case "classic", "cg", "legacy", "legacy-only", "false", "0", "no":
            return .legacy
        default:
            return .auto
        }
    }

    static func outputPath(
        path: String?,
        format: ImageFormat,
        defaultDirectory: String,
        defaultFileName: String
    ) -> String {
        if let path {
            return ObservationOutputPathResolver.resolve(
                path: path,
                format: format,
                defaultFileName: defaultFileName
            ).path
        }

        return (defaultDirectory as NSString).appendingPathComponent(defaultFileName)
    }
}
