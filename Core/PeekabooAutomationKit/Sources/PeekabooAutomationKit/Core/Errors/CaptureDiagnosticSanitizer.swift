import Foundation

enum CaptureDiagnosticSanitizer {
    static let maximumUTF8Bytes = 512

    static func sanitize(_ value: String?, maximumUTF8Bytes: Int = Self.maximumUTF8Bytes) -> String? {
        guard let value, maximumUTF8Bytes > 0 else { return nil }
        let ellipsis = "…"
        let contentBudget = max(0, maximumUTF8Bytes - ellipsis.utf8.count)
        var output = ""
        var byteCount = 0
        var pendingSpace = false
        var truncated = false
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                pendingSpace = !output.isEmpty
                continue
            }
            let text = String(scalar)
            let additionalBytes = text.utf8.count + (pendingSpace ? 1 : 0)
            guard byteCount + additionalBytes <= contentBudget else {
                truncated = true
                break
            }
            if pendingSpace {
                output.append(" ")
                byteCount += 1
                pendingSpace = false
            }
            output.append(text)
            byteCount += text.utf8.count
        }
        guard !output.isEmpty else { return nil }
        return truncated ? output + ellipsis : output
    }
}
