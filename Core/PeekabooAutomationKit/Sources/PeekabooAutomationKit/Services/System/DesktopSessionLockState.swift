import CoreGraphics
import Foundation

enum DesktopSessionLockState {
    private static let screenIsLockedKey = "CGSSessionScreenIsLocked"

    static func currentScreenIsLocked() -> Bool? {
        self.screenIsLocked(in: CGSessionCopyCurrentDictionary() as NSDictionary?)
    }

    static func screenIsLocked(in session: NSDictionary?) -> Bool? {
        session?[self.screenIsLockedKey] as? Bool
    }
}
