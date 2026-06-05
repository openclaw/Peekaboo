import AppKit
import Foundation
import UniformTypeIdentifiers

/// Representation of a single pasteboard payload.
public struct ClipboardRepresentation: Sendable {
    public let utiIdentifier: String
    public let data: Data

    public init(utiIdentifier: String, data: Data) {
        self.utiIdentifier = utiIdentifier
        self.data = data
    }
}

/// Request to write multiple representations to the clipboard.
public struct ClipboardWriteRequest: Sendable {
    public var representations: [ClipboardRepresentation]
    public var alsoText: String?
    public var allowLarge: Bool

    public init(
        representations: [ClipboardRepresentation],
        alsoText: String? = nil,
        allowLarge: Bool = false)
    {
        self.representations = representations
        self.alsoText = alsoText
        self.allowLarge = allowLarge
    }
}

extension ClipboardWriteRequest {
    public static func textRepresentations(from data: Data) -> [ClipboardRepresentation] {
        [
            ClipboardRepresentation(utiIdentifier: UTType.plainText.identifier, data: data),
            ClipboardRepresentation(utiIdentifier: NSPasteboard.PasteboardType.string.rawValue, data: data),
        ]
    }
}

/// Result returned after reading the clipboard.
public struct ClipboardReadResult: Sendable {
    public let utiIdentifier: String
    public let data: Data
    public let textPreview: String?

    public init(utiIdentifier: String, data: Data, textPreview: String?) {
        self.utiIdentifier = utiIdentifier
        self.data = data
        self.textPreview = textPreview
    }
}

/// Possible errors thrown by the clipboard service.
public enum ClipboardServiceError: LocalizedError, Sendable {
    case empty
    case sizeExceeded(current: Int, limit: Int)
    case slotNotFound(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Clipboard is empty."
        case let .sizeExceeded(current, limit):
            "Clipboard write blocked: size \(current) bytes exceeds \(limit) bytes. Use allowLarge to override."
        case let .slotNotFound(slot):
            "Clipboard slot '\(slot)' not found."
        case let .writeFailed(reason):
            "Failed to write to clipboard: \(reason)"
        }
    }
}

/// Protocol describing clipboard operations.
@MainActor
public protocol ClipboardServiceProtocol: Sendable {
    func get(prefer uti: UTType?) throws -> ClipboardReadResult?
    func set(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult
    func clear()
    func save(slot: String) throws
    func restore(slot: String) throws -> ClipboardReadResult
}

/// Default implementation backed by NSPasteboard.
@MainActor
public final class ClipboardService: ClipboardServiceProtocol {
    private let pasteboard: NSPasteboard
    private let sizeLimit: Int
    private var slots: [String: [ClipboardRepresentation]] = [:]

    public init(pasteboard: NSPasteboard = .general, sizeLimit: Int = 10 * 1024 * 1024) {
        self.pasteboard = pasteboard
        self.sizeLimit = sizeLimit
    }

    // MARK: - Slot storage (cross-process)

    private func slotPasteboardName(for slot: String) -> NSPasteboard.Name {
        let sanitizedSlot = slot
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .map { scalar -> String in
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
                return allowed.contains(scalar) ? String(Character(scalar)) : "_"
            }
            .joined()

        return NSPasteboard.Name("\(self.pasteboard.name.rawValue).boo.peekaboo.clipboard.slot.\(sanitizedSlot)")
    }

    // MARK: - Public API

    public func get(prefer uti: UTType?) throws -> ClipboardReadResult? {
        guard let types = self.pasteboard.types, !types.isEmpty else { return nil }

        let targetType: NSPasteboard.PasteboardType = if let uti,
                                                         let preferred = types
                                                             .first(where: { $0.rawValue == uti.identifier })
        {
            preferred
        } else if let stringType = types.first(where: { $0 == .string || $0 == .init("public.utf8-plain-text") }) {
            stringType
        } else {
            types[0]
        }

        let data: Data?
        var textPreview: String?

        if targetType == .string, let string = self.pasteboard.string(forType: .string) {
            let normalized = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
                of: "\r",
                with: "\n")
            data = normalized.data(using: .utf8)
            textPreview = Self.makePreview(normalized)
        } else {
            data = self.pasteboard.data(forType: targetType)
            if let data, let string = String(data: data, encoding: .utf8) {
                textPreview = Self.makePreview(string)
            }
        }

        guard let data else { return nil }

        return ClipboardReadResult(
            utiIdentifier: targetType.rawValue,
            data: data,
            textPreview: textPreview)
    }

    public func set(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        guard !request.representations.isEmpty else {
            throw ClipboardServiceError.writeFailed("No representations provided.")
        }

        let totalSize = request.representations.reduce(0) { $0 + $1.data.count } +
            (request.alsoText?.utf8.count ?? 0)
        if !request.allowLarge, totalSize > self.sizeLimit {
            throw ClipboardServiceError.sizeExceeded(current: totalSize, limit: self.sizeLimit)
        }

        var types = request.representations.map { NSPasteboard.PasteboardType($0.utiIdentifier) }
        let includesTextType = request.representations.contains(where: Self.isPlainTextRepresentation)
        if request.alsoText != nil || includesTextType {
            if !types.contains(.string) {
                types.append(.string)
            }
        }
        self.pasteboard.declareTypes(types, owner: nil)

        for representation in request.representations {
            let pbType = NSPasteboard.PasteboardType(representation.utiIdentifier)
            guard self.pasteboard.setData(representation.data, forType: pbType) else {
                throw ClipboardServiceError.writeFailed("Unable to set type \(representation.utiIdentifier)")
            }
        }

        if let alsoText = request.alsoText {
            self.pasteboard.setString(alsoText, forType: .string)
        } else if let representation = request.representations.first(where: Self.isPlainTextRepresentation),
                  let fallbackText = String(data: representation.data, encoding: .utf8)
        {
            self.pasteboard.setString(fallbackText, forType: .string)
        }

        let primary = request.representations.first!
        let preview: String? = if let text = request.alsoText {
            Self.makePreview(text)
        } else if Self.isPlainTextRepresentation(primary),
                  let string = String(data: primary.data, encoding: .utf8)
        {
            Self.makePreview(string)
        } else {
            nil
        }

        return ClipboardReadResult(
            utiIdentifier: primary.utiIdentifier,
            data: primary.data,
            textPreview: preview)
    }

    public func clear() {
        self.pasteboard.clearContents()
    }

    public func save(slot: String) throws {
        let trimmedSlot = slot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSlot.isEmpty else {
            throw ClipboardServiceError.writeFailed("Slot name must not be empty.")
        }

        let reps = self.snapshotCurrentRepresentations()
        self.slots[trimmedSlot] = reps

        let slotPasteboard = NSPasteboard(name: self.slotPasteboardName(for: trimmedSlot))
        slotPasteboard.clearContents()
        let types = reps.map { NSPasteboard.PasteboardType($0.utiIdentifier) }
        slotPasteboard.declareTypes(types, owner: nil)

        for rep in reps {
            let pbType = NSPasteboard.PasteboardType(rep.utiIdentifier)
            guard slotPasteboard.setData(rep.data, forType: pbType) else {
                throw ClipboardServiceError
                    .writeFailed("Unable to save type \(rep.utiIdentifier) to slot \(trimmedSlot)")
            }
        }
    }

    public func restore(slot: String) throws -> ClipboardReadResult {
        let trimmedSlot = slot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSlot.isEmpty else {
            throw ClipboardServiceError.slotNotFound(slot)
        }

        let slotPasteboardName = self.slotPasteboardName(for: trimmedSlot)
        let reps: [ClipboardRepresentation]
        if let cached = self.slots[trimmedSlot], !cached.isEmpty {
            reps = cached
        } else {
            let slotPasteboard = NSPasteboard(name: slotPasteboardName)
            let loaded = self.snapshotRepresentations(from: slotPasteboard)
            guard !loaded.isEmpty else {
                throw ClipboardServiceError.slotNotFound(trimmedSlot)
            }
            reps = loaded
        }

        let request = ClipboardWriteRequest(representations: reps)
        let result = try self.set(request)
        self.slots.removeValue(forKey: trimmedSlot)
        NSPasteboard(name: slotPasteboardName).clearContents()
        return result
    }

    // MARK: - Helpers

    private func snapshotCurrentRepresentations() -> [ClipboardRepresentation] {
        self.snapshotRepresentations(from: self.pasteboard)
    }

    private func snapshotRepresentations(from pasteboard: NSPasteboard) -> [ClipboardRepresentation] {
        var reps: [ClipboardRepresentation] = []

        if let items = pasteboard.pasteboardItems {
            for item in items {
                for type in item.types {
                    if let data = item.data(forType: type) {
                        reps.append(ClipboardRepresentation(utiIdentifier: type.rawValue, data: data))
                    }
                }
            }
        }

        if !reps.isEmpty {
            return reps
        }

        guard let types = pasteboard.types else { return [] }
        for type in types {
            if let data = pasteboard.data(forType: type) {
                reps.append(ClipboardRepresentation(utiIdentifier: type.rawValue, data: data))
            }
        }

        return reps
    }

    private static func isPlainTextRepresentation(_ representation: ClipboardRepresentation) -> Bool {
        representation.utiIdentifier == UTType.plainText.identifier ||
            representation.utiIdentifier == UTType.utf8PlainText.identifier
    }

    private static func makePreview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let max = 80
        guard trimmed.count > max else { return trimmed }
        let head = trimmed.prefix(max)
        return "\(head)…"
    }
}
