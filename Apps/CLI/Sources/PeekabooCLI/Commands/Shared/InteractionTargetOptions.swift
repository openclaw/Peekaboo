import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Shared targeting options for interaction commands.
///
/// These options are always optional. When you provide a window selector, an app selector must be present.
struct InteractionTargetOptions: CommanderParsable, ApplicationResolvable {
    @Option(name: .long, help: "Target application name, bundle ID, or 'PID:12345'")
    var app: String?

    @Option(name: .long, help: "Target application by process ID")
    var pid: Int32?

    @Option(name: .long, help: "Target window by title (partial match supported)")
    var windowTitle: String?

    @Option(name: .long, help: "Target window by index (0-based, frontmost is 0)")
    var windowIndex: Int?

    @Option(
        name: .long,
        help: "Target window by CoreGraphics window id (window_id from `peekaboo window list --json`)"
    )
    var windowId: Int?

    init() {}

    var hasAnyTarget: Bool {
        self.app != nil || self.pid != nil || self.windowTitle != nil || self.windowIndex != nil || self.windowId != nil
    }

    func validateSelectorCombination() throws {
        try InteractionTargetSelectorValidator.validateCLI(
            hasApplication: self.app != nil,
            hasProcessIdentifier: self.pid != nil,
            hasWindowID: self.windowId != nil,
            hasWindowTitle: self.windowTitle != nil,
            hasWindowIndex: self.windowIndex != nil
        )
    }

    func validate() throws {
        try self.validateSelectorCombination()

        if let windowIndex = self.windowIndex, windowIndex < 0 {
            throw ValidationError("--window-index must be 0 or greater")
        }

        if let windowId = self.windowId, windowId <= 0 || UInt32(exactly: windowId) == nil {
            throw ValidationError("--window-id must be between 1 and \(UInt32.max)")
        }
    }

    func resolveApplicationIdentifierOptional() throws -> String? {
        try self.validate()
        guard self.app != nil || self.pid != nil else {
            return nil
        }
        return try self.resolveApplicationIdentifier()
    }

    func resolveWindowID(services: any PeekabooServiceProviding) async throws -> CGWindowID? {
        try self.validate()
        if let windowId = self.windowId {
            return CGWindowID(windowId)
        }

        guard let windowIndex = self.windowIndex else {
            return nil
        }

        guard let appIdentifier = try self.resolveApplicationIdentifierOptional() else {
            throw ValidationError("Missing --app/--pid for --window-index")
        }

        let windows = try await services.windows.listWindows(target: .index(app: appIdentifier, index: windowIndex))
        guard let window = windows.first else {
            return nil
        }

        return CGWindowID(window.windowID)
    }

    func resolveWindowTitleOptional(services: any PeekabooServiceProviding) async throws -> String? {
        try self.validate()
        if let windowTitle {
            return windowTitle
        }

        if let windowId = self.windowId {
            let windows = try await services.windows.listWindows(target: .windowId(windowId))
            return windows.first?.title
        }

        guard let windowIndex = self.windowIndex else {
            return nil
        }

        guard let appIdentifier = try self.resolveApplicationIdentifierOptional() else {
            throw ValidationError("Missing --app/--pid for --window-index")
        }

        let windows = try await services.windows.listWindows(target: .index(app: appIdentifier, index: windowIndex))
        return windows.first?.title
    }

    func toWindowTarget() throws -> WindowTarget? {
        try self.validate()
        if let windowId {
            return .windowId(windowId)
        }

        guard let appIdentifier = try self.resolveApplicationIdentifierOptional() else {
            return nil
        }

        if let windowTitle = self.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !windowTitle.isEmpty {
            return .applicationAndTitle(app: appIdentifier, title: windowTitle)
        }

        if let windowIndex {
            return .index(app: appIdentifier, index: windowIndex)
        }

        return .application(appIdentifier)
    }

    func dialogTargetSelector() throws -> DialogTargetSelector {
        try self.validate()
        return try DialogTargetSelector(
            applicationIdentifier: self.app,
            processIdentifier: self.pid,
            windowID: self.windowId,
            windowTitle: self.windowTitle,
            windowIndex: self.windowIndex
        )
    }
}

extension InteractionTargetSelectorValidator {
    static func validateCLI(
        hasApplication: Bool,
        hasProcessIdentifier: Bool,
        hasWindowID: Bool,
        hasWindowTitle: Bool,
        hasWindowIndex: Bool
    ) throws {
        do {
            try self.validate(
                hasApplication: hasApplication,
                hasProcessIdentifier: hasProcessIdentifier,
                hasWindowID: hasWindowID,
                hasWindowTitle: hasWindowTitle,
                hasWindowIndex: hasWindowIndex
            )
        } catch let error as InteractionTargetSelectorValidationError {
            let message = switch error {
            case .applicationAndProcessIdentifier:
                "Use either --app or --pid, not both."
            case .multipleWindowSelectors:
                "Use only one of --window-id, --window-title, or --window-index."
            case .windowSelectorRequiresApplication:
                "--window-title and --window-index require --app or --pid."
            }
            throw ValidationError(message)
        }
    }
}
