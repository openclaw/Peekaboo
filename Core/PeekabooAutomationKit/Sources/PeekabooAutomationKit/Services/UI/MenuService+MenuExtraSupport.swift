//
//  MenuService+MenuExtraSupport.swift
//  PeekabooCore
//

import CoreFoundation
import CoreGraphics
import Foundation

@MainActor
extension MenuService {
    @_spi(Testing) public static func mergeMenuExtras(
        accessibilityExtras: [MenuExtraInfo],
        fallbackExtras: [MenuExtraInfo]) -> [MenuExtraInfo]
    {
        var merged = [MenuExtraInfo]()

        func upsert(_ extra: MenuExtraInfo) {
            let bothHavePosition = extra.position != .zero && merged.contains { $0.position != .zero }
            if bothHavePosition,
               let index = merged.firstIndex(where: { $0.position.distance(to: extra.position) < 5 })
            {
                merged[index] = merged[index].merging(with: extra)
            } else {
                merged.append(extra)
            }
        }

        fallbackExtras.forEach(upsert)
        accessibilityExtras.forEach(upsert)

        merged.sort { $0.position.x < $1.position.x }
        return merged
    }

    func makeMenuExtraDisplayName(
        rawTitle: String?,
        ownerName: String?,
        bundleIdentifier: String?,
        identifier: String? = nil) -> String
    {
        var resolved = rawTitle?.isEmpty == false ? rawTitle! : (ownerName ?? "Unknown")
        let namespace = MenuExtraNamespace(bundleIdentifier: bundleIdentifier)
        switch namespace {
        case .controlCenter:
            if isPlaceholderMenuTitle(resolved) {
                resolved = "Control Center"
            }
        case .systemUIServer:
            if resolved.lowercased() == "menu extras" {
                resolved = "System Menu Extras"
            }
        case .spotlight:
            if isPlaceholderMenuTitle(resolved) {
                resolved = "Spotlight"
            }
        case .siri:
            if isPlaceholderMenuTitle(resolved) {
                resolved = "Siri"
            }
        case .passwords:
            if isPlaceholderMenuTitle(resolved) {
                resolved = "Passwords"
            }
        case .other:
            break
        }

        let identifierSource = identifier ?? rawTitle
        if let identifierName = humanReadableMenuIdentifier(identifierSource),
           isPlaceholderMenuTitle(resolved)
        {
            self.logger.debug("MenuService replacing placeholder '\(resolved)' with identifier '\(identifierName)'")
            return identifierName
        }

        if isPlaceholderMenuTitle(resolved),
           let ownerName,
           !ownerName.isEmpty
        {
            self.logger.debug("MenuService replacing placeholder '\(resolved)' with owner '\(ownerName)'")
            return ownerName
        }

        if namespace == .controlCenter,
           resolved.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           resolved.count > 4,
           resolved.range(of: #"[A-Z].*[a-z]|[a-z].*[A-Z]"#, options: .regularExpression) != nil
        {
            let humanized = camelCaseToWords(resolved)
            if !humanized.isEmpty, !isPlaceholderMenuTitle(humanized) {
                return humanized
            }
        }

        return resolved
    }
}

// MARK: - Helpers

extension CGEventField {
    static let windowID = CGEventField(rawValue: 0x33)!
}

private enum MenuExtraNamespace {
    case controlCenter, systemUIServer, spotlight, siri, passwords, other

    init(bundleIdentifier: String?) {
        switch bundleIdentifier {
        case "com.apple.controlcenter": self = .controlCenter
        case "com.apple.systemuiserver": self = .systemUIServer
        case "com.apple.Spotlight": self = .spotlight
        case "com.apple.Siri": self = .siri
        case "com.apple.Passwords.MenuBarExtra": self = .passwords
        default: self = .other
        }
    }
}

@_spi(Testing) public func humanReadableMenuIdentifier(
    _ identifier: String?,
    lookup: ControlCenterIdentifierLookup = .shared) -> String?
{
    guard let identifier = sanitizedMenuText(identifier) else { return nil }

    if let mapped = lookup.displayName(for: identifier) {
        return mapped
    }

    let separators = CharacterSet(charactersIn: "._-:/")
    let tokens = identifier.split { character in
        character.unicodeScalars.contains { separators.contains($0) }
    }
    guard let rawToken = tokens.last else { return nil }
    let candidate = String(rawToken)
    guard !isPlaceholderMenuTitle(candidate) else { return nil }
    let spaced = camelCaseToWords(candidate)
    return spaced.isEmpty ? nil : spaced
}

func camelCaseToWords(_ token: String) -> String {
    var result = ""
    var previousWasUppercase = false

    for character in token {
        if character == "_" || character == "-" {
            if !result.hasSuffix(" ") {
                result.append(" ")
            }
            previousWasUppercase = false
            continue
        }

        if character.isUppercase, !previousWasUppercase, !result.isEmpty {
            result.append(" ")
        }

        result.append(character)
        previousWasUppercase = character.isUppercase
    }

    return result
        .replacingOccurrences(of: "  ", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .capitalized
}

@_spi(Testing) public struct ControlCenterIdentifierLookup: Sendable {
    @_spi(Testing) public static let shared = ControlCenterIdentifierLookup()

    private let mapping: [String: String]

    @_spi(Testing) public init(mapping: [String: String]) {
        self.mapping = mapping
    }

    public init() {
        self.mapping = Self.loadMapping()
    }

    @_spi(Testing) public func displayName(for identifier: String) -> String? {
        let upper = identifier.uppercased()
        return self.mapping[upper]
    }

    private static func loadMapping() -> [String: String] {
        guard let rawValue = CFPreferencesCopyAppValue(
            "ControlCenterDisplayableChronoControlsProviderConfiguration" as CFString,
            "com.apple.controlcenter" as CFString)
        else {
            return [:]
        }

        let data: Data
        if let string = rawValue as? String {
            data = Data(string.utf8)
        } else if let dataValue = rawValue as? Data {
            data = dataValue
        } else if let nsData = rawValue as? NSData {
            data = nsData as Data
        } else {
            return [:]
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let controls = json["Controls"] as? [[String: Any]]
        else {
            return [:]
        }

        var mapping: [String: String] = [:]
        for control in controls {
            guard let displayName = control["DisplayName"] as? String else { continue }
            guard let identifiers = control["Identifier"] as? [String] else { continue }
            for identifier in identifiers {
                let key = identifier.uppercased()
                if mapping[key] == nil {
                    mapping[key] = displayName
                }
            }
        }
        return mapping
    }
}

extension MenuExtraInfo {
    fileprivate func merging(with candidate: MenuExtraInfo) -> MenuExtraInfo {
        MenuExtraInfo(
            title: Self.preferredTitle(primary: self, secondary: candidate) ?? self.title,
            rawTitle: self.rawTitle ?? candidate.rawTitle,
            bundleIdentifier: self.bundleIdentifier ?? candidate.bundleIdentifier,
            ownerName: self.ownerName ?? candidate.ownerName,
            position: self.preferredPosition(comparedTo: candidate),
            isVisible: self.preferredVisibility(comparedTo: candidate),
            identifier: self.identifier ?? candidate.identifier,
            windowID: self.windowID ?? candidate.windowID,
            windowLayer: self.windowLayer ?? candidate.windowLayer,
            ownerPID: self.ownerPID ?? candidate.ownerPID,
            source: self.source ?? candidate.source)
    }

    private func preferredVisibility(comparedTo candidate: MenuExtraInfo) -> Bool {
        if self.windowID != nil {
            return self.isVisible
        }
        if candidate.windowID != nil {
            return candidate.isVisible
        }
        return self.isVisible || candidate.isVisible
    }

    private static func preferredTitle(primary: MenuExtraInfo, secondary: MenuExtraInfo) -> String? {
        let primaryTitle = sanitizedMenuText(primary.title) ?? sanitizedMenuText(primary.rawTitle)
        let secondaryTitle = sanitizedMenuText(secondary.title) ?? sanitizedMenuText(secondary.rawTitle)

        let primaryQuality = Self.titleQuality(for: primaryTitle)
        let secondaryQuality = Self.titleQuality(for: secondaryTitle)

        if secondaryQuality > primaryQuality {
            return secondaryTitle ?? primaryTitle
        } else if primaryQuality > secondaryQuality {
            return primaryTitle ?? secondaryTitle
        } else {
            return primaryTitle ?? secondaryTitle
        }
    }

    private static func titleQuality(for title: String?) -> Int {
        guard let title else { return 0 }
        if isPlaceholderMenuTitle(title) { return 0 }
        if title.count <= 2 { return 1 }
        if title.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            return 2
        }
        return 3
    }

    private func preferredPosition(comparedTo candidate: MenuExtraInfo) -> CGPoint {
        if self.position.distance(to: candidate.position) <= 1 {
            return self.position
        }
        return self.position.x <= candidate.position.x ? self.position : candidate.position
    }
}

extension CGPoint {
    fileprivate func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
