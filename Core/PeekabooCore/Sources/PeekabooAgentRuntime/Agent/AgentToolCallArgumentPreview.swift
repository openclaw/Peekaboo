//
//  AgentToolCallArgumentPreview.swift
//  PeekabooCore
//

import Foundation

enum AgentToolCallArgumentPreview {
    /// Redact obviously sensitive fields before previewing tool-call arguments.
    /// Masks inline dataBase64 payloads, sensitive keys, and inline secret patterns.
    static func redacted(from data: Data, maxLength: Int = 320) -> String {
        let rawText = String(data: data, encoding: .utf8) ?? "{}"
        let text: String = if let object = try? JSONSerialization.jsonObject(with: data),
                              let redacted = Self.redactSensitiveValues(object),
                              let cleaned = try? JSONSerialization.data(withJSONObject: redacted),
                              let cleanedText = String(data: cleaned, encoding: .utf8)
        {
            Self.regexRedact(cleanedText)
        } else {
            Self.regexRedact(rawText)
        }

        guard text.count > maxLength else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<endIndex]) + "…"
    }

    private static func redactSensitiveValues(_ value: Any) -> Any? {
        switch value {
        case let dict as [String: Any]:
            var copy: [String: Any] = [:]
            for (key, value) in dict {
                if Self.isSensitiveKey(key) {
                    copy[key] = "***"
                } else if let redacted = Self.redactSensitiveValues(value) {
                    copy[key] = redacted
                }
            }
            return copy

        case let array as [Any]:
            return array.compactMap { Self.redactSensitiveValues($0) }

        case let string as String:
            if string.lowercased().contains("bearer ") {
                return "Bearer ***"
            }
            if string.lowercased().contains("api_key") {
                return "***"
            }
            return string

        default:
            return value
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lowerKey = key.lowercased()
        return lowerKey == "database64" ||
            lowerKey.contains("token") ||
            lowerKey.contains("secret") ||
            lowerKey.contains("password") ||
            lowerKey.contains("key") ||
            lowerKey.contains("auth") ||
            lowerKey.contains("cookie") ||
            lowerKey.contains("authorization")
    }

    private static func regexRedact(_ text: String) -> String {
        let patterns = [
            "(?i)sk-[a-z0-9_-]{10,}",
            "(?i)bearer\\s+[a-z0-9._-]{8,}",
            "(?i)api[_-]?key\\s*[:=]\\s*[a-z0-9._-]{6,}",
            "(?i)sess[a-z0-9]{12,}",
            "(?i)token\\s*[:=]\\s*[a-z0-9._-]{12,}",
        ]

        var output = text
        for pattern in patterns {
            output = output.replacingOccurrences(of: pattern, with: "***", options: .regularExpression)
        }
        return output
    }
}
