import Darwin
import Foundation
import PeekabooFoundation

extension ConfigurationManager {
    /// Load configuration from a specific path
    func loadConfigurationFromPath(_ configPath: String) -> Configuration? {
        guard FileManager.default.fileExists(atPath: configPath) else {
            return nil
        }

        var expandedJSON = ""

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let jsonString = String(data: data, encoding: .utf8) ?? ""
            let cleanedJSON = self.stripJSONComments(from: jsonString)
            expandedJSON = self.expandEnvironmentVariables(in: cleanedJSON, preservingKeys: ["apiKey"])

            if let expandedData = expandedJSON.data(using: .utf8) {
                let config = try JSONCoding.decoder.decode(Configuration.self, from: expandedData)
                self.configuration = config
                return config
            }
        } catch let error as DecodingError {
            self.printDecodingWarning(error, expandedJSON: expandedJSON)
        } catch {
            self.printWarning("Failed to load configuration from \(configPath): \(error)")
        }

        return nil
    }

    /// Strip comments from JSONC content
    public func stripJSONComments(from json: String) -> String {
        var stripper = JSONCommentStripper(json: json)
        return stripper.strip()
    }

    /// Expand environment variables in the format `${VAR_NAME}`.
    public func expandEnvironmentVariables(in text: String) -> String {
        self.expandEnvironmentVariables(in: text, preservingKeys: [])
    }

    /// Expand environment variables in the format `${VAR_NAME}` except in selected JSON string properties.
    func expandEnvironmentVariables(in text: String, preservingKeys: Set<String>) -> String {
        let pattern = #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#

        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(location: 0, length: text.utf16.count)
            var result = text

            // Reverse replacement keeps each regex match range valid against the original string.
            for match in regex.matches(in: text, options: [], range: range).reversed() {
                if let propertyName = self.jsonStringPropertyName(containing: match, in: text),
                   preservingKeys.contains(propertyName)
                {
                    continue
                }

                let varNameRange = match.range(at: 1)
                if let swiftRange = Range(varNameRange, in: text) {
                    let varName = String(text[swiftRange])
                    if let value = self.environmentValue(for: varName),
                       let fullMatch = Range(match.range, in: text)
                    {
                        result.replaceSubrange(fullMatch, with: value)
                    }
                }
            }

            return result
        } catch {
            return text
        }
    }

    private func jsonStringPropertyName(containing match: NSTextCheckingResult, in text: String) -> String? {
        guard let matchRange = Range(match.range, in: text) else { return nil }
        let prefix = String(text[..<matchRange.lowerBound])
        let pattern = #""((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }

        let range = NSRange(location: 0, length: prefix.utf16.count)
        guard let match = regex.matches(in: prefix, options: [], range: range).last,
              let keyRange = Range(match.range(at: 1), in: prefix)
        else {
            return nil
        }

        return String(prefix[keyRange])
    }

    func environmentValue(for key: String) -> String? {
        guard let rawValue = getenv(key) else {
            return nil
        }
        return String(cString: rawValue)
    }

    private func printDecodingWarning(_ error: DecodingError, expandedJSON: String) {
        switch error {
        case let .keyNotFound(key, context):
            let path = self.codingPathDescription(context)
            self.printWarning("JSON key not found '\(key.stringValue)' at path: \(path)")
        case let .typeMismatch(type, context):
            let path = self.codingPathDescription(context)
            self.printWarning("Type mismatch for type '\(type)' at path: \(path)")
        case let .valueNotFound(type, context):
            let path = self.codingPathDescription(context)
            self.printWarning("Value not found for type '\(type)' at path: \(path)")
        case let .dataCorrupted(context):
            let path = self.codingPathDescription(context)
            self.printWarning("Data corrupted at path: \(path)")
            if let underlyingError = context.underlyingError {
                print("Underlying error: \(underlyingError)")
            }
        @unknown default:
            self.printWarning("Unknown decoding error: \(error)")
        }

        if expandedJSON.count < 5000 {
            self.printWarning("Cleaned JSON that failed to parse:")
            print(expandedJSON)
        }
    }

    private func printWarning(_ message: String) {
        print("Warning: \(message)")
    }

    private func codingPathDescription(_ context: DecodingError.Context) -> String {
        context.codingPath.map(\.stringValue).joined(separator: ".")
    }
}

private struct JSONCommentStripper {
    private let characters: [Character]
    private var index: Int = 0
    private var result = ""
    private var inString = false
    private var escapeNext = false
    private var singleLineComment = false
    private var multiLineComment = false

    init(json: String) {
        self.characters = Array(json)
    }

    mutating func strip() -> String {
        while self.index < self.characters.count {
            let char = self.characters[self.index]
            let next = self.peek()

            if self.handleEscape(char) { continue }
            if self.handleQuote(char) { continue }
            if self.inString {
                self.append(char)
                self.advance()
                continue
            }
            if self.handleCommentStart(char, next) { continue }
            if self.handleCommentEnd(char, next) { continue }
            self.appendIfNeeded(char)
            self.advance()
        }

        return self.result
    }

    private mutating func handleEscape(_ char: Character) -> Bool {
        if self.escapeNext {
            self.append(char)
            self.escapeNext = false
            self.advance()
            return true
        }

        if char == "\\", self.inString {
            self.escapeNext = true
            self.append(char)
            self.advance()
            return true
        }

        return false
    }

    private mutating func handleQuote(_ char: Character) -> Bool {
        guard char == "\"", !self.singleLineComment, !self.multiLineComment else { return false }
        self.inString.toggle()
        self.append(char)
        self.advance()
        return true
    }

    private mutating func handleCommentStart(_ char: Character, _ next: Character?) -> Bool {
        if char == "/", next == "/", !self.multiLineComment {
            self.singleLineComment = true
            self.advance(by: 2)
            return true
        }

        if char == "/", next == "*", !self.singleLineComment {
            self.multiLineComment = true
            self.advance(by: 2)
            return true
        }

        return false
    }

    private mutating func handleCommentEnd(_ char: Character, _ next: Character?) -> Bool {
        if char == "\n", self.singleLineComment {
            self.singleLineComment = false
            self.append(char)
            self.advance()
            return true
        }

        if char == "*", next == "/", self.multiLineComment {
            self.multiLineComment = false
            self.advance(by: 2)
            return true
        }

        return false
    }

    private mutating func appendIfNeeded(_ char: Character) {
        guard !self.singleLineComment, !self.multiLineComment else { return }
        self.append(char)
    }

    private mutating func append(_ char: Character) {
        self.result.append(char)
    }

    private mutating func advance(by value: Int = 1) {
        self.index += value
    }

    private func peek() -> Character? {
        (self.index + 1) < self.characters.count ? self.characters[self.index + 1] : nil
    }
}
