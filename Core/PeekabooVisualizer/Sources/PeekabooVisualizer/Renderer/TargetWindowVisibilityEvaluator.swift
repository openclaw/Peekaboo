import AppKit
import CoreGraphics
import PeekabooFoundation

enum TargetWindowVisibilityEvaluator {
    static func visibleTarget(_ target: VisualizerTargetWindow) -> VisualizerTargetWindow? {
        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier),
              application.isActive,
              !application.isHidden,
              let info = CGWindowListCopyWindowInfo(
                  [.optionAll, .excludeDesktopElements],
                  kCGNullWindowID) as? [[String: Any]],
              let window = info.first(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.windowID &&
                      ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.processIdentifier
              }),
              (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let globalFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
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
}
