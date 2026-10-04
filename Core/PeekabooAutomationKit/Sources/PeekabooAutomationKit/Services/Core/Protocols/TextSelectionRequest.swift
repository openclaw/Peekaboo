import Foundation
import PeekabooFoundation

public enum TextSelectionType: String, Codable, CaseIterable, Sendable {
    case text
    case cursorBefore = "cursor_before"
    case cursorAfter = "cursor_after"
}

/// Literal text and immediately adjacent context; all returned offsets use native UTF-16 units.
public struct TextSelectionRequest: Codable, Equatable, Sendable {
    public let text: String
    public let prefix: String?
    public let suffix: String?
    public let selectionType: TextSelectionType

    public init(
        text: String,
        prefix: String? = nil,
        suffix: String? = nil,
        selectionType: TextSelectionType = .text)
    {
        self.text = text
        self.prefix = prefix
        self.suffix = suffix
        self.selectionType = selectionType
    }

    public func resolve(in source: String) throws -> TextSelectionResult {
        guard !self.text.isEmpty else {
            throw PeekabooError.invalidInput("Selection text must not be empty")
        }
        let value = source as NSString
        let prefix = self.prefix.map { Array($0.utf16) } ?? []
        let suffix = self.suffix.map { Array($0.utf16) } ?? []
        let units = Array(source.utf16)
        var search = NSRange(location: 0, length: value.length)
        var match: TextSelectionRange?
        while search.length > 0 {
            let found = value.range(of: self.text, options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            let end = found.location + found.length
            if found.location >= prefix.count, end + suffix.count <= units.count,
               units[(found.location - prefix.count)..<found.location].elementsEqual(prefix),
               units[end..<(end + suffix.count)].elementsEqual(suffix)
            {
                guard match == nil else {
                    throw PeekabooError.invalidInput("Selection text is ambiguous; provide a unique prefix or suffix")
                }
                match = TextSelectionRange(location: found.location, length: found.length)
            }
            let next = found.location + 1
            search = NSRange(location: next, length: value.length - next)
        }
        guard let match else {
            throw PeekabooError.invalidInput("Selection text and context were not found in the target")
        }
        guard let result = TextSelectionResult(matchedRange: match, selectionType: self.selectionType) else {
            throw PeekabooError.invalidInput("Selection range is not representable")
        }
        return result
    }
}

public struct TextSelectionResult: Codable, Equatable, Sendable {
    public let matchedRange: TextSelectionRange
    public let selectedRange: TextSelectionRange
    public let selectionType: TextSelectionType

    public init?(matchedRange: TextSelectionRange, selectionType: TextSelectionType) {
        guard matchedRange.length > 0 else { return nil }
        let selectedRange: TextSelectionRange? = switch selectionType {
        case .text:
            matchedRange
        case .cursorBefore:
            TextSelectionRange(location: matchedRange.location, length: 0)
        case .cursorAfter:
            TextSelectionRange(location: matchedRange.location + matchedRange.length, length: 0)
        }
        guard let selectedRange else { return nil }
        self.matchedRange = matchedRange
        self.selectionType = selectionType
        self.selectedRange = selectedRange
    }

    public func matches(_ request: TextSelectionRequest) -> Bool {
        guard let expected = Self(matchedRange: self.matchedRange, selectionType: request.selectionType)
        else { return false }
        return !request.text.isEmpty && self.matchedRange.length == request.text.utf16.count &&
            self.selectionType == request.selectionType &&
            self == expected
    }
}

struct TextSelectionState: Equatable {
    let text: String
    let range: TextSelectionRange

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text.utf16.elementsEqual(rhs.text.utf16) && lhs.range == rhs.range
    }
}

extension ElementActionResult {
    public func matchesTextSelection(target: String, request: TextSelectionRequest) -> Bool {
        self.target == target && self.actionName == "AXSelectedTextRange" &&
            self.anchorPoint == nil && self.oldValue == nil && self.newValue == nil &&
            self.valueVerification == nil && self.textSelection?.matches(request) == true
    }
}
