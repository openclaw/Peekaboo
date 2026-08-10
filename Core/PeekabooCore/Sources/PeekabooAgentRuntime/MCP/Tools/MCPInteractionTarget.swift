import CoreGraphics
import Foundation
import PeekabooAutomation
import PeekabooFoundation

enum MCPInteractionTargetError: LocalizedError, Equatable {
    case applicationAndProcessIdentifier
    case multipleWindowSelectors
    case windowSelectorRequiresApp
    case invalidWindowId
    case invalidWindowIndex
    case invalidProcessIdentifier
    case backgroundTargetRequired
    case backgroundWindowTargetUnsupported
    case targetProcessNotFound

    var errorDescription: String? {
        switch self {
        case .applicationAndProcessIdentifier:
            "app and pid are mutually exclusive; provide exactly one process selector."
        case .multipleWindowSelectors:
            "window_id, window_title, and window_index are mutually exclusive; provide at most one."
        case .windowSelectorRequiresApp:
            "window_title and window_index require app or pid so the window can be resolved deterministically."
        case .invalidWindowId:
            "window_id must be between 1 and \(UInt32.max)."
        case .invalidWindowIndex:
            "window_index must be 0 or greater."
        case .invalidProcessIdentifier:
            "pid must be a positive 32-bit integer."
        case .backgroundTargetRequired:
            "Background keyboard input requires app or pid targeting. " +
                "Set foreground=true for intentional global input."
        case .backgroundWindowTargetUnsupported:
            "Background keyboard delivery cannot safely target a specific window. " +
                "Use app/pid without a window selector, or set foreground=true to focus the window first."
        case .targetProcessNotFound:
            "Could not resolve a running target process. Check the app/pid, or set foreground=true for intentional " +
                "global input."
        }
    }
}

struct MCPInteractionTarget {
    let app: String?
    let pid: Int?
    let windowTitle: String?
    let windowIndex: Int?
    let windowId: Int?

    init(
        app: String?,
        pid: Int?,
        windowTitle: String?,
        windowIndex: Int?,
        windowId: Int?) throws
    {
        self.app = app
        self.pid = pid
        self.windowTitle = windowTitle
        self.windowIndex = windowIndex
        self.windowId = windowId
        try self.validate()
    }

    var appIdentifier: String? {
        if let pid {
            return "PID:\(pid)"
        }
        return self.app
    }

    func validate() throws {
        do {
            try InteractionTargetSelectorValidator.validate(
                hasApplication: self.app != nil,
                hasProcessIdentifier: self.pid != nil,
                hasWindowID: self.windowId != nil,
                hasWindowTitle: self.windowTitle != nil,
                hasWindowIndex: self.windowIndex != nil)
        } catch let error as InteractionTargetSelectorValidationError {
            switch error {
            case .applicationAndProcessIdentifier:
                throw MCPInteractionTargetError.applicationAndProcessIdentifier
            case .multipleWindowSelectors:
                throw MCPInteractionTargetError.multipleWindowSelectors
            case .windowSelectorRequiresApplication:
                throw MCPInteractionTargetError.windowSelectorRequiresApp
            }
        }

        if let pid, pid <= 0 || Int32(exactly: pid) == nil {
            throw MCPInteractionTargetError.invalidProcessIdentifier
        }

        if let windowId, windowId <= 0 || CGWindowID(exactly: windowId) == nil {
            throw MCPInteractionTargetError.invalidWindowId
        }

        if let windowIndex, windowIndex < 0 {
            throw MCPInteractionTargetError.invalidWindowIndex
        }
    }

    func toWindowTarget() throws -> WindowTarget? {
        try self.validate()

        if let windowId {
            return .windowId(windowId)
        }

        if let title = self.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            if let appId = self.appIdentifier, !appId.isEmpty {
                return .applicationAndTitle(app: appId, title: title)
            }
            return .title(title)
        }

        if let windowIndex {
            return .index(app: self.appIdentifier ?? "", index: windowIndex)
        }

        if let appId = self.appIdentifier, !appId.isEmpty {
            return .application(appId)
        }

        return nil
    }

    func focusIfRequested(windows: any WindowManagementServiceProtocol) async throws -> WindowTarget? {
        let target = try self.toWindowTarget()
        guard let target else { return nil }
        try await windows.focusWindow(target: target)
        return target
    }

    func processIdentifier(
        applications: any ApplicationServiceProtocol,
        windows: any WindowManagementServiceProtocol) async throws -> pid_t?
    {
        if let windowId {
            return Self.processIdentifierForWindow(windowId: CGWindowID(windowId))
        }

        if self.windowTitle != nil || self.windowIndex != nil {
            guard let target = try self.toWindowTarget() else { return nil }
            let matchingWindows = try await windows.listWindows(target: target)
            guard let windowId = matchingWindows.first?.windowID else { return nil }
            if let pid = Self.processIdentifierForWindow(windowId: CGWindowID(windowId)) {
                return pid
            }
        }

        if let pid, pid > 0 {
            return pid_t(pid)
        }

        if let appIdentifier = self.app?.trimmingCharacters(in: .whitespacesAndNewlines),
           !appIdentifier.isEmpty
        {
            let app = try await applications.findApplication(identifier: appIdentifier)
            return pid_t(app.processIdentifier)
        }

        guard let target = try self.toWindowTarget() else { return nil }
        let matchingWindows = try await windows.listWindows(target: target)
        guard let windowId = matchingWindows.first?.windowID else { return nil }
        return Self.processIdentifierForWindow(windowId: CGWindowID(windowId))
    }

    private static func processIdentifierForWindow(windowId: CGWindowID) -> pid_t? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else {
            return nil
        }

        return windowList.first { window in
            self.windowID(from: window[kCGWindowNumber as String]) == windowId
        }.flatMap { window in
            self.pid(from: window[kCGWindowOwnerPID as String])
        }
    }

    private static func windowID(from value: Any?) -> CGWindowID? {
        self.intValue(from: value).map(CGWindowID.init)
    }

    private static func pid(from value: Any?) -> pid_t? {
        self.intValue(from: value).map(pid_t.init)
    }

    private static func intValue(from value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let int = value as? Int {
            return int
        }
        if let int32 = value as? Int32 {
            return Int(int32)
        }
        if let uint32 = value as? UInt32 {
            return Int(uint32)
        }
        return nil
    }

    var hasTarget: Bool {
        self.pid != nil ||
            !(self.app?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
            self.windowId != nil ||
            self.windowIndex != nil ||
            !(self.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var hasWindowSelector: Bool {
        self.windowId != nil || self.windowIndex != nil ||
            !(self.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func requireBackgroundProcessIdentifier(
        applications: any ApplicationServiceProtocol,
        windows: any WindowManagementServiceProtocol) async throws -> pid_t
    {
        try self.validate()
        guard self.hasTarget else {
            throw MCPInteractionTargetError.backgroundTargetRequired
        }
        guard !self.hasWindowSelector else {
            throw MCPInteractionTargetError.backgroundWindowTargetUnsupported
        }
        guard let processIdentifier = try await self.processIdentifierIfTargeted(
            applications: applications,
            windows: windows), processIdentifier > 0
        else {
            throw MCPInteractionTargetError.targetProcessNotFound
        }
        return processIdentifier
    }

    func focusIfRequested(windows: any WindowManagementServiceProtocol, onlyWhenTargeted: Bool) async throws
        -> WindowTarget?
    {
        guard !onlyWhenTargeted || self.hasTarget else { return nil }
        return try await self.focusIfRequested(windows: windows)
    }

    func processIdentifierIfTargeted(
        applications: any ApplicationServiceProtocol,
        windows: any WindowManagementServiceProtocol) async throws -> pid_t?
    {
        guard self.hasTarget else { return nil }
        return try await self.processIdentifier(applications: applications, windows: windows)
    }

    func targetProcessIdentifierValue(
        applications: any ApplicationServiceProtocol,
        windows: any WindowManagementServiceProtocol) async throws -> Int?
    {
        guard let pid = try await self.processIdentifierIfTargeted(applications: applications, windows: windows) else {
            return nil
        }
        return Int(pid)
    }

    func resolveWindowTitleIfNeeded(windows: any WindowManagementServiceProtocol) async throws -> String? {
        if let windowTitle, !windowTitle.isEmpty {
            return windowTitle
        }

        // Only attempt a lookup when the user used an ID/index selector.
        guard self.windowId != nil || self.windowIndex != nil else { return nil }
        guard let target = try self.toWindowTarget() else { return nil }

        let windowsInfo = try await windows.listWindows(target: target)
        return windowsInfo.first?.title
    }
}
