import CoreGraphics
import Foundation
import PeekabooCore

struct MenuBarVerifyTarget {
    let title: String?
    let ownerPID: pid_t?
    let ownerName: String?
    let bundleIdentifier: String?
    let preferredX: CGFloat?
}

struct MenuBarClickVerification {
    let verified: Bool
    let method: String
    let windowId: Int?
}

struct MenuBarFocusSnapshot {
    let appPID: pid_t
    let appName: String
    let bundleIdentifier: String?
    let windowId: Int?
    let windowTitle: String?
    let windowBounds: CGRect?
}

func matchMenuBarItem(named name: String, items: [MenuBarItemInfo]) -> MenuBarItemInfo? {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let candidates: [(MenuBarItemInfo, [String])] = items.map { item in
        let fields = [
            item.title,
            item.rawTitle,
            item.identifier,
            item.axDescription,
            item.ownerName,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return (item, fields)
    }

    if let exact = candidates.first(where: { _, fields in fields.contains(normalized) })?.0 {
        return exact
    }

    let hyphens = "-‐‑‒–—"
    func foldingHyphens(_ value: String) -> String {
        String(value.filter { !hyphens.contains($0) })
    }
    let foldedName = foldingHyphens(normalized)
    if let folded = candidates.first(where: { _, fields in
        fields.contains(where: { foldingHyphens($0) == foldedName })
    })?.0 {
        return folded
    }

    return candidates.first(where: { _, fields in
        fields.contains(where: { $0.contains(normalized) })
    })?.0
}
