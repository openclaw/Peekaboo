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

func matchMenuBarItem(named name: String, items: [MenuBarItemInfo]) throws -> MenuBarItemInfo? {
    do {
        return try MenuBarItemSelector.select(named: name, from: items).candidate.value
    } catch let error as DesktopLeafSelectionError {
        if case .notFound = error {
            return nil
        }
        throw error
    }
}
