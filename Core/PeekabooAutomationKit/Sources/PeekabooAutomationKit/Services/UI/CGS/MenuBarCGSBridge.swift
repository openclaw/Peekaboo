import CoreGraphics
import Darwin
import Foundation

// Thin wrappers around private CGS APIs to enumerate menu bar item windows.
// Mirrors Ice’s bridging to reach status item windows hosted by Control Center on macOS 26.

/// Option bits (mirrored from Ice)
private struct CGSWindowListOption: OptionSet {
    let rawValue: UInt32
    static let onScreen = CGSWindowListOption(rawValue: 1 << 0)
    static let menuBarItems = CGSWindowListOption(rawValue: 1 << 1)
    static let activeSpace = CGSWindowListOption(rawValue: 1 << 2)
}

// MARK: - Dynamic loading helpers

private func loadCGSHandle() -> UnsafeMutableRawPointer? {
    let handles = [
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    ]

    for path in handles {
        if let found = dlopen(path, RTLD_NOW) {
            return found
        }
    }
    return nil
}

private func loadSymbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let handle = loadCGSHandle(), let sym = dlsym(handle, name) else {
        return nil
    }
    return unsafeBitCast(sym, to: T.self)
}

/// Return window IDs for menu bar items (status items), optionally filtered to on-screen/active space.
/// Uses private CGS calls; failures should be treated as “no data.”
func cgsMenuBarWindowIDs(onScreen: Bool = false, activeSpace: Bool = false) -> [CGWindowID] {
    typealias CGSConnectionID = UInt32
    typealias CGSMainConnectionFunc = @convention(c) () -> CGSConnectionID
    typealias CGSCopyWindowsFunc = @convention(c) (CGSConnectionID, Int32, UInt32) -> CFArray?

    guard
        let mainConn = loadSymbol("CGSMainConnectionID", as: CGSMainConnectionFunc.self),
        let copyWin = loadSymbol("CGSCopyWindowsWithOptions", as: CGSCopyWindowsFunc.self)
    else {
        return []
    }

    let cid = mainConn()
    var opts: CGSWindowListOption = .menuBarItems
    if onScreen {
        opts.insert(.onScreen)
    }
    if activeSpace {
        opts.insert(.activeSpace)
    }

    guard let raw = copyWin(cid, 0, opts.rawValue) as? [UInt32] else {
        return []
    }
    var ids = raw.map { CGWindowID($0) }
    if activeSpace {
        ids = ids.filter { cgsIsWindowOnActiveSpace($0) }
    }
    return ids
}

/// Alternative private API used by Ice: enumerate menu bar windows per process.
/// This appears to surface third-party extras that `CGSCopyWindowsWithOptions` sometimes misses.
func cgsProcessMenuBarWindowIDs(onScreenOnly: Bool = true) -> [CGWindowID] {
    typealias CGSConnectionID = Int32
    typealias CGSMainConnectionFunc = @convention(c) () -> CGSConnectionID
    typealias CGSGetWindowCountFunc = @convention(c) (CGSConnectionID, CGSConnectionID, UnsafeMutablePointer<Int32>)
        -> Int32
    typealias CGSGetProcessMenuBarWindowListFunc = @convention(c) (
        CGSConnectionID, CGSConnectionID, Int32, UnsafeMutablePointer<CGWindowID>, UnsafeMutablePointer<Int32>) -> Int32
    typealias CGSGetOnScreenWindowCountFunc = @convention(c) (
        CGSConnectionID,
        CGSConnectionID,
        UnsafeMutablePointer<Int32>) -> Int32
    typealias CGSGetOnScreenWindowListFunc = @convention(c) (
        CGSConnectionID, CGSConnectionID, Int32, UnsafeMutablePointer<CGWindowID>, UnsafeMutablePointer<Int32>) -> Int32
    typealias CGSCopySpacesForWindowsFunc = @convention(c) (CGSConnectionID, UInt32, CFArray) -> Unmanaged<CFArray>?
    typealias CGSGetActiveSpaceFunc = @convention(c) (CGSConnectionID) -> UInt32

    guard
        let mainConn = loadSymbol("CGSMainConnectionID", as: CGSMainConnectionFunc.self),
        let getCount = loadSymbol("CGSGetWindowCount", as: CGSGetWindowCountFunc.self),
        let getMenuBarList = loadSymbol("CGSGetProcessMenuBarWindowList", as: CGSGetProcessMenuBarWindowListFunc.self),
        let getOnScreenCount = loadSymbol("CGSGetOnScreenWindowCount", as: CGSGetOnScreenWindowCountFunc.self),
        let getOnScreenList = loadSymbol("CGSGetOnScreenWindowList", as: CGSGetOnScreenWindowListFunc.self),
        let copySpaces = loadSymbol("CGSCopySpacesForWindows", as: CGSCopySpacesForWindowsFunc.self),
        let getActiveSpace = loadSymbol("CGSGetActiveSpace", as: CGSGetActiveSpaceFunc.self)
    else {
        return []
    }

    let connection = mainConn()
    guard var ids = CGSWindowIDList.read(
        count: { getCount(connection, 0, $0) },
        list: { getMenuBarList(connection, 0, $0, $1, $2) })
    else { return [] }

    if onScreenOnly,
       let onScreen = CGSWindowIDList.read(
           count: { getOnScreenCount(connection, 0, $0) },
           list: { getOnScreenList(connection, 0, $0, $1, $2) })
    {
        let filter = Set(onScreen)
        ids = ids.filter { filter.contains($0) }
    }

    // Active space filter to mirror Ice.
    let activeSpace = getActiveSpace(mainConn())
    ids = ids.filter { windowID in
        guard let spaces = copySpaces(mainConn(), 1 << 0 /* includes current */, [windowID] as CFArray)?
            .takeRetainedValue() as? [UInt32]
        else { return true }
        return spaces.contains(activeSpace)
    }

    return ids
}

// MARK: - Active Space Helper

private func cgsIsWindowOnActiveSpace(_ windowID: CGWindowID) -> Bool {
    typealias CGSConnectionID = Int32
    typealias CGSMainConnectionFunc = @convention(c) () -> CGSConnectionID
    typealias CGSCopySpacesForWindowsFunc = @convention(c) (CGSConnectionID, UInt32, CFArray) -> Unmanaged<CFArray>?
    typealias CGSGetActiveSpaceFunc = @convention(c) (CGSConnectionID) -> UInt32

    guard
        let mainConn = loadSymbol("CGSMainConnectionID", as: CGSMainConnectionFunc.self),
        let copySpaces = loadSymbol("CGSCopySpacesForWindows", as: CGSCopySpacesForWindowsFunc.self),
        let getActiveSpace = loadSymbol("CGSGetActiveSpace", as: CGSGetActiveSpaceFunc.self)
    else {
        return true
    }

    let cid = mainConn()
    let activeSpace = getActiveSpace(cid)
    guard let spaces = copySpaces(cid, 1 << 0 /* includes current */, [windowID] as CFArray)?
        .takeRetainedValue() as? [UInt32]
    else { return true }
    return spaces.contains(activeSpace)
}
