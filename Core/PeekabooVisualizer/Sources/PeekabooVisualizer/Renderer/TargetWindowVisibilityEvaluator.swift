import AppKit
import CoreGraphics
import PeekabooFoundation

enum TargetWindowVisibilityEvaluator {
    static func visibleTarget(_ target: VisualizerTargetWindow) -> VisualizerTargetWindow? {
        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier),
              application.isActive,
              !application.isHidden,
              let info = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID) as? [[String: Any]],
              let globalFrame = self.frontmostWindowBounds(
                  ofPID: target.processIdentifier,
                  windowID: target.windowID,
                  in: info)
        else {
            return nil
        }
        return VisualizerTargetWindow(
            processIdentifier: target.processIdentifier,
            windowID: target.windowID,
            frame: VisualizerScreenGeometry.appKitRect(
                fromGlobalDisplay: globalFrame,
                primaryScreenFrame: NSScreen.screens.first?.frame))
    }

    /// Returns the bounds of `windowID` only when it is the frontmost ordinary
    /// (layer-0, opaque, on-screen) window of `pid` in the given front-to-back
    /// window list. A target occluded by a sibling window must not anchor input
    /// feedback: the HUD would reveal keystrokes over a surface the user cannot
    /// see the target through.
    static func frontmostWindowBounds(
        ofPID pid: Int32,
        windowID: UInt32,
        in windowInfo: [[String: Any]]) -> CGRect?
    {
        for window in windowInfo {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
            else { continue }
            guard (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else {
                return nil
            }
            return frame
        }
        return nil
    }
}
