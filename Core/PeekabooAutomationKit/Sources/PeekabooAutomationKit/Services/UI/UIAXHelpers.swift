//
//  UIAXHelpers.swift
//  PeekabooCore
//

import AppKit
import AXorcist
import Foundation
import OSLog

// MARK: - Title helpers

func sanitizedMenuText(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

@_spi(Testing) public func isPlaceholderMenuTitle(_ title: String?) -> Bool {
    guard let sanitized = sanitizedMenuText(title) else { return true }
    let lower = sanitized.lowercased()
    if lower == "unknown" || lower == "item" || lower == "menu item" {
        return true
    }
    if lower.hasPrefix("item-") || lower.hasPrefix("item ") {
        return true
    }
    if lower.hasPrefix("bentobox") || lower.hasPrefix("menubaritem") {
        return true
    }
    if sanitized.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil {
        return true
    }
    if sanitized.range(of: #"^[0-9a-fA-F\-]{8,}$"#, options: .regularExpression) != nil {
        return true
    }
    return false
}

@_spi(Testing) public func normalizedMenuTitle(_ value: String?) -> String? {
    guard let sanitized = sanitizedMenuText(value) else { return nil }

    // Normalize common accelerator / ellipsis variants
    let ellipsisReplaced = sanitized
        .replacingOccurrences(of: "…", with: "")
        .replacingOccurrences(of: "\u{2026}", with: "")
        .replacingOccurrences(of: "...", with: "")
        .replacingOccurrences(of: "&", with: "")

    let strippedAccelerators = ellipsisReplaced
        .replacingOccurrences(
            of: #"(&[A-Za-z])|⌘|Ctrl\+|Alt\+|Option\+|Shift\+|⇧|⌃|⌥|⌘"#,
            with: " ",
            options: .regularExpression)

    let folded = strippedAccelerators.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    let collapsed = folded
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")

    return collapsed.isEmpty ? nil : collapsed
}

@_spi(Testing) public func titlesMatch(candidate: String?, target: String, normalizedTarget: String? = nil) -> Bool {
    guard let candidateNormalized = normalizedMenuTitle(candidate) else { return false }
    let targetNormalized = normalizedTarget ?? normalizedMenuTitle(target)
    return candidateNormalized == targetNormalized
}

@_spi(Testing) public func menuExtraTitlesMatch(candidate: String?, target: String) -> Bool {
    if titlesMatch(candidate: candidate, target: target) {
        return true
    }

    func foldingHyphens(_ value: String?) -> String? {
        normalizedMenuTitle(value)?.replacingOccurrences(
            of: #"[-‐‑‒–—]"#,
            with: "",
            options: .regularExpression)
    }

    guard let candidateNormalized = foldingHyphens(candidate),
          let targetNormalized = foldingHyphens(target)
    else { return false }
    return candidateNormalized == targetNormalized
}

@_spi(Testing) public func titlesMatchPartial(
    candidate: String?,
    target: String,
    normalizedTarget: String? = nil) -> Bool
{
    guard let candidateNormalized = normalizedMenuTitle(candidate) else { return false }
    let targetNormalized = normalizedTarget ?? normalizedMenuTitle(target)
    guard let targetNormalized else { return false }
    return candidateNormalized.contains(targetNormalized)
}

@_spi(Testing) public func menuTitleCandidatesContainNormalized(
    _ candidates: [String?],
    normalizedTarget: String) -> Bool
{
    let target = normalizedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return false }

    for candidate in candidates {
        guard let candidateNormalized = normalizedMenuTitle(candidate) else { continue }
        if candidateNormalized.contains(target) {
            return true
        }
    }
    return false
}
