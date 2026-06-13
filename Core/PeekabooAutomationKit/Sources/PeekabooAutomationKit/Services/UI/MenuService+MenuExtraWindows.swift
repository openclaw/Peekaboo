//
//  MenuService+MenuExtraWindows.swift
//  PeekabooCore
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
extension MenuService {
    func getMenuBarItemsViaWindows() -> [MenuExtraInfo] {
        var items: [MenuExtraInfo] = []
        let displayBounds = self.activeDisplayBounds()

        // Preferred: call LSUIElement helper (AppKit context) to get WindowServer view like Ice.
        if let helperItems = self.getMenuBarItemsViaHelper(displayBounds: displayBounds), !helperItems.isEmpty {
            self.logger.debug("MenuService helper returned \(helperItems.count) items")
            return helperItems
        }

        // Preferred path: CGS menuBarItems window list (private API, mirrored from Ice).
        let cgsIDs = cgsMenuBarWindowIDs(onScreen: true, activeSpace: true)
        let legacyIDs = cgsProcessMenuBarWindowIDs(onScreenOnly: true)
        let combinedIDs = Array(Set(cgsIDs + legacyIDs))
        self.logger.debug(
            """
            CGS menuBarItems returned \(cgsIDs.count) ids;
            processMenuBar returned \(legacyIDs.count); combined \(combinedIDs.count)
            """)
        var seenIDs = Set<CGWindowID>()
        if !combinedIDs.isEmpty {
            // Use CGWindow metadata per window ID to resolve owner/bundle.
            for id in combinedIDs {
                if let item = self.makeMenuExtra(from: id, displayBounds: displayBounds) {
                    items.append(item)
                    seenIDs.insert(id)
                } else {
                    self.logger.debug("CGS menu item window \(id) had no metadata")
                }
            }
        } else {
            self.logger.debug("CGS menuBarItems returned 0 ids; falling back to CGWindowList")
        }

        // Fallback: public CGWindowList heuristics.
        let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] ?? []

        for windowInfo in windowList {
            guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard !seenIDs.contains(windowID) else { continue }
            if let item = self.makeMenuExtra(from: windowID, info: windowInfo, displayBounds: displayBounds) {
                items.append(item)
                seenIDs.insert(windowID)
            }
        }

        return items
    }

    func resolveMenuExtraClickPoint(for extra: MenuExtraInfo) -> CGPoint? {
        if let windowID = extra.windowID,
           let bounds = self.windowBounds(for: windowID)
        {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }

        if extra.position != .zero {
            return extra.position
        }

        return nil
    }

    func isMenuExtraPointVisible(_ point: CGPoint) -> Bool {
        Self.isMenuExtraPointVisible(point, displayBounds: self.activeDisplayBounds())
    }

    func isMenuExtraAXPositionVisible(_ position: CGPoint) -> Bool {
        position != .zero && self.isMenuExtraPointVisible(position)
    }

    static func isMenuExtraPointVisible(_ point: CGPoint, displayBounds: [CGRect]) -> Bool {
        displayBounds.contains { $0.contains(point) }
    }

    static func isMenuExtraFrameVisible(_ frame: CGRect, displayBounds: [CGRect]) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        return self.isMenuExtraPointVisible(
            CGPoint(x: frame.midX, y: frame.midY),
            displayBounds: displayBounds)
    }

    static func isIndividuallyHiddenMenuExtra(
        position: CGPoint,
        allPositions: [CGPoint],
        displayBounds: [CGRect]) -> Bool
    {
        guard position != .zero,
              !self.isMenuExtraPointVisible(position, displayBounds: displayBounds)
        else {
            return false
        }

        return allPositions.contains { candidate in
            candidate != .zero && self.isMenuExtraPointVisible(candidate, displayBounds: displayBounds)
        }
    }

    func activeDisplayBounds() -> [CGRect] {
        let appKitBounds: () -> [CGRect] = {
            NSScreen.screens.compactMap { screen in
                guard let displayID = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber"),
                ] as? CGDirectDisplayID
                else {
                    return nil
                }
                return CGDisplayBounds(displayID)
            }
        }

        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return appKitBounds()
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
            return appKitBounds()
        }
        return displayIDs.prefix(Int(displayCount)).map { CGDisplayBounds($0) }
    }

    func windowBounds(for windowID: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let first = info.first,
              let boundsDict = first[kCGWindowBounds as String] as? [String: Any],
              let x = boundsDict["X"] as? CGFloat,
              let y = boundsDict["Y"] as? CGFloat,
              let width = boundsDict["Width"] as? CGFloat,
              let height = boundsDict["Height"] as? CGFloat
        else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    func tryWindowTargetedClick(extra: MenuExtraInfo, point: CGPoint) -> Bool {
        guard self.isMenuExtraPointVisible(point) else {
            return false
        }
        guard let windowID = extra.windowID else {
            return false
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }

        let userData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(source)))
        let windowIDValue = Int64(windowID)

        guard
            let down = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left),
            let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left)
        else {
            return false
        }

        if let ownerPID = extra.ownerPID {
            let pidValue = Int64(ownerPID)
            down.setIntegerValueField(.eventTargetUnixProcessID, value: pidValue)
            up.setIntegerValueField(.eventTargetUnixProcessID, value: pidValue)
        }

        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: userData)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowIDValue)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowIDValue)
            event.setIntegerValueField(.windowID, value: windowIDValue)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }

        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    func isLikelyMenuBarAXPosition(_ position: CGPoint) -> Bool {
        guard position != .zero else { return true }
        return position.y <= self.menuBarAXMaxY(for: position)
    }

    func menuBarAXMaxY(for position: CGPoint) -> CGFloat {
        let fallbackHeight: CGFloat = 24
        let matchingScreens = NSScreen.screens.filter { screen in
            position.x >= screen.frame.minX && position.x <= screen.frame.maxX
        }
        let candidateScreens = matchingScreens.isEmpty ? NSScreen.screens : matchingScreens
        return candidateScreens
            .map { screen in
                let height = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
                return (height > 0 ? height : fallbackHeight) + 12
            }
            .max() ?? fallbackHeight + 12
    }

    /// Invoke the LSUIElement helper (if built) to enumerate menu bar windows from a GUI context.
    func getMenuBarItemsViaHelper(displayBounds: [CGRect]) -> [MenuExtraInfo]? {
        let helperPath = [
            FileManager.default.currentDirectoryPath,
            "Helpers",
            "MenuBarHelper",
            "build",
            "MenubarHelper.app",
            "Contents",
            "MacOS",
            "menubar-helper",
        ].joined(separator: "/")
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            return nil
        }

        let process = Process()
        process.launchPath = helperPath

        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            self.logger.debug("Failed to run menubar helper: \(error.localizedDescription)")
            return nil
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = json["window_ids"] as? [UInt32]
        else { return nil }

        // Enrich each window ID locally via CGWindowList so we can keep coordinates/owner.
        var items: [MenuExtraInfo] = []
        for id in ids {
            if let item = self.makeMenuExtra(from: CGWindowID(id), displayBounds: displayBounds) {
                items.append(item)
            }
        }
        return items
    }

    func makeMenuExtra(
        from windowID: CGWindowID,
        info: [String: Any]? = nil,
        displayBounds: [CGRect]) -> MenuExtraInfo?
    {
        let windowInfo: [String: Any]
        if let info {
            windowInfo = info
        } else if let refreshed = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
                  let first = refreshed.first
        {
            windowInfo = first
        } else {
            return nil
        }

        let windowLayer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
        if !(windowLayer == 24 || windowLayer == 25) { return nil }

        guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let x = boundsDict["X"] as? CGFloat,
              let y = boundsDict["Y"] as? CGFloat,
              let width = boundsDict["Width"] as? CGFloat,
              let height = boundsDict["Height"] as? CGFloat
        else {
            return nil
        }

        guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? "Unknown"
        let windowTitle = windowInfo[kCGWindowName as String] as? String ?? ""
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let isVisible = Self.isMenuExtraFrameVisible(frame, displayBounds: displayBounds)

        if ownerName == "Window Server", windowTitle == "Menubar" {
            return nil
        }

        var bundleID: String?
        if let app = NSRunningApplication(processIdentifier: ownerPID) {
            bundleID = app.bundleIdentifier
            // If window title is empty, prefer localized app name for display.
            if windowTitle.isEmpty, let appName = app.localizedName {
                return MenuExtraInfo(
                    title: self.makeMenuExtraDisplayName(
                        rawTitle: appName,
                        ownerName: appName,
                        bundleIdentifier: bundleID),
                    rawTitle: windowTitle.isEmpty ? appName : windowTitle,
                    bundleIdentifier: bundleID,
                    ownerName: appName,
                    position: CGPoint(x: x + width / 2, y: y + height / 2),
                    isVisible: isVisible,
                    identifier: bundleID ?? windowTitle,
                    windowID: windowID,
                    windowLayer: windowLayer,
                    ownerPID: ownerPID,
                    source: info == nil ? "cgs" : "cgwindow")
            }
        }

        if bundleID == "com.apple.finder", windowTitle.isEmpty {
            return nil
        }

        let titleOrOwner = windowTitle.isEmpty ? ownerName : windowTitle
        let friendlyTitle = self.makeMenuExtraDisplayName(
            rawTitle: titleOrOwner, ownerName: ownerName, bundleIdentifier: bundleID)

        return MenuExtraInfo(
            title: friendlyTitle,
            rawTitle: titleOrOwner,
            bundleIdentifier: bundleID,
            ownerName: ownerName,
            position: CGPoint(x: x + width / 2, y: y + height / 2),
            isVisible: isVisible,
            identifier: bundleID ?? windowTitle,
            windowID: windowID,
            windowLayer: windowLayer,
            ownerPID: ownerPID,
            source: info == nil ? "cgs" : "cgwindow")
    }
}
