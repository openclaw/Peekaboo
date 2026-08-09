import AppKit
import CoreGraphics
import PeekabooFoundation

enum VisualizerTargetWindowResolver {
    @MainActor
    static func frontmostWindow() -> VisualizerTargetWindow? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              !application.isHidden,
              application.isActive
        else {
            return nil
        }

        return self.onScreenWindows()
            .first { $0.processIdentifier == application.processIdentifier }
    }

    static func target(from context: WindowContext?) -> VisualizerTargetWindow? {
        guard let context,
              let processIdentifier = context.applicationProcessId,
              let rawWindowID = context.windowID,
              let windowID = UInt32(exactly: rawWindowID),
              let frame = context.windowBounds
        else {
            return nil
        }

        let capturedTarget = VisualizerTargetWindow(
            processIdentifier: processIdentifier,
            windowID: windowID,
            frame: frame)
        return self.onScreenWindows().first {
            $0.processIdentifier == processIdentifier && $0.windowID == windowID
        } ?? capturedTarget
    }

    private static func onScreenWindows() -> [VisualizerTargetWindow] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]]
        else {
            return []
        }

        return windowInfo.compactMap { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 1,
                  frame.height > 1
            else {
                return nil
            }

            return VisualizerTargetWindow(
                processIdentifier: ownerPID.int32Value,
                windowID: number.uint32Value,
                frame: frame)
        }
    }
}

extension UIAutomationService {
    func visualizerTargetWindow(snapshotId: String?) async -> VisualizerTargetWindow? {
        if let snapshotId,
           let result = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotId),
           let target = VisualizerTargetWindowResolver.target(from: result.metadata.windowContext)
        {
            return target
        }
        return VisualizerTargetWindowResolver.frontmostWindow()
    }
}
