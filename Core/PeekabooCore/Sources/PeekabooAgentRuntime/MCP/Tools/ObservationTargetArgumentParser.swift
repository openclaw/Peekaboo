import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation

enum ObservationTargetArgument: Equatable, CustomStringConvertible {
    case screen(index: Int?)
    case frontmost
    case application(identifier: String, window: WindowSelection)
    case pid(Int32, window: WindowSelection)
    case windowID(CGWindowID)
    case menubar

    var observationTarget: DesktopObservationTargetRequest {
        switch self {
        case let .screen(index):
            .screen(index: index)
        case .frontmost:
            .frontmost
        case let .application(identifier, window):
            .app(identifier: identifier, window: window)
        case let .pid(pid, window):
            .pid(pid, window: window)
        case let .windowID(windowID):
            .windowID(windowID)
        case .menubar:
            .menubar
        }
    }

    var focusIdentifier: String? {
        switch self {
        case let .application(identifier, _):
            identifier
        case let .pid(pid, _):
            "PID:\(pid)"
        case .screen, .frontmost, .windowID, .menubar:
            nil
        }
    }

    var requiresStableMutationTarget: Bool {
        switch self {
        case .pid, .windowID:
            true
        case .screen, .frontmost, .application, .menubar:
            false
        }
    }

    var description: String {
        switch self {
        case let .screen(index):
            "screen:\(index.map(String.init) ?? "primary")"
        case .frontmost:
            "frontmost"
        case let .application(identifier, window):
            "\(identifier)\(Self.windowDescription(window))"
        case let .pid(pid, window):
            "PID:\(pid)\(Self.windowDescription(window))"
        case let .windowID(windowID):
            "window-id:\(windowID)"
        case .menubar:
            "menubar"
        }
    }

    static func parse(_ rawTarget: String?, windowIDValue: Value?) throws -> ObservationTargetArgument {
        let parsed = try self.parse(rawTarget)
        guard let exactWindowID = try self.exactWindowID(from: windowIDValue) else { return parsed }
        let hasExplicitTarget = rawTarget?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if !hasExplicitTarget {
            return .windowID(exactWindowID)
        }

        switch parsed {
        case let .application(identifier, .automatic):
            return .application(identifier: identifier, window: .id(exactWindowID))
        case let .pid(pid, .automatic):
            return .pid(pid, window: .id(exactWindowID))
        case .application, .pid:
            throw PeekabooError.invalidInput(
                "window_id cannot be combined with an app_target window title or index")
        case .screen, .frontmost, .windowID, .menubar:
            throw PeekabooError.invalidInput(
                "window_id cannot be combined with this app_target")
        }
    }

    private static func exactWindowID(from value: Value?) throws -> CGWindowID? {
        guard let value else { return nil }
        guard case let .int(windowID) = value else {
            throw PeekabooError.invalidInput("window_id must be an integer")
        }
        guard windowID > 0, let exactWindowID = CGWindowID(exactly: windowID) else {
            throw PeekabooError.invalidInput("window_id must be between 1 and \(UInt32.max)")
        }
        return exactWindowID
    }

    static func parse(_ rawTarget: String?) throws -> ObservationTargetArgument {
        guard let rawTarget,
              !rawTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .screen(index: nil)
        }

        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = target.lowercased()

        if lowercased.hasPrefix("screen:") {
            let indexString = String(target.dropFirst("screen:".count))
            guard let index = Int(indexString) else {
                throw PeekabooError.invalidInput("Invalid screen index: \(indexString)")
            }
            return .screen(index: index)
        }

        switch lowercased {
        case "screen":
            return .screen(index: nil)
        case "frontmost":
            return .frontmost
        case "menubar":
            return .menubar
        default:
            break
        }

        if lowercased.hasPrefix("pid:") {
            let parts = target.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, let pid = Int32(parts[1]) else {
                throw PeekabooError.invalidInput("Invalid PID target: \(target)")
            }
            return .pid(pid, window: self.windowSelection(from: parts.dropFirst(2).first))
        }

        let parts = target.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let appIdentifier = parts.first, !appIdentifier.isEmpty else {
            throw PeekabooError.invalidInput("Invalid app target: \(target)")
        }
        return .application(
            identifier: String(appIdentifier),
            window: self.windowSelection(from: parts.dropFirst().first))
    }

    private static func windowSelection(from rawValue: String.SubSequence?) -> WindowSelection {
        guard let rawValue else {
            return .automatic
        }

        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return .automatic
        }

        if let index = Int(value) {
            return .index(index)
        }
        return .title(value)
    }

    private static func windowDescription(_ selection: WindowSelection) -> String {
        switch selection {
        case .automatic:
            ""
        case let .index(index):
            ":\(index)"
        case let .title(title):
            ":\(title)"
        case let .id(windowID):
            ":window-id-\(windowID)"
        }
    }
}
