import Commander
import CoreGraphics
import Foundation
import PeekabooCore

@MainActor
struct WindowIdentificationOptions: CommanderParsable, ApplicationResolvable {
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

    enum CodingKeys: String, CodingKey {
        case app
        case pid
        case windowId
        case windowTitle
        case windowIndex
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.app = try container.decodeIfPresent(String.self, forKey: .app)
        self.pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
        self.windowId = try container.decodeIfPresent(Int.self, forKey: .windowId)
        self.windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        self.windowIndex = try container.decodeIfPresent(Int.self, forKey: .windowIndex)
    }

    func validate(allowMissingTarget: Bool = false) throws {
        if let windowId = self.windowId, windowId <= 0 {
            throw ValidationError("--window-id must be greater than 0")
        }

        // Ensure we have some way to identify the window
        if self.app == nil && self.pid == nil && self.windowId == nil && !allowMissingTarget {
            throw ValidationError("Either --app, --pid, or --window-id must be specified")
        }

        if let index = self.windowIndex, index < 0 {
            throw ValidationError("--window-index must be 0 or greater")
        }
    }

    /// Convert to WindowTarget for service layer
    func toWindowTarget() throws -> WindowTarget {
        // Convert to WindowTarget for service layer
        if let windowId = self.windowId {
            return .windowId(windowId)
        }

        let appIdentifier = try self.resolveApplicationIdentifier()

        if let title = self.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return .applicationAndTitle(app: appIdentifier, title: title)
        } else if let index = windowIndex {
            return .index(app: appIdentifier, index: index)
        } else {
            // Default to app's frontmost window
            return .application(appIdentifier)
        }
    }
}

extension WindowIdentificationOptions {
    private var hasApplicationTarget: Bool {
        self.app != nil || self.pid != nil
    }

    @MainActor
    func resolveApplicationInfoIfNeeded(
        services: any PeekabooServiceProviding
    ) async throws -> ServiceApplicationInfo? {
        guard self.hasApplicationTarget else {
            return nil
        }
        let identifier = try self.resolveApplicationIdentifier()
        return try await services.applications.findApplication(identifier: identifier)
    }

    func displayName(windowInfo: ServiceWindowInfo?) -> String {
        if let app {
            return app
        }
        if let pid {
            return "PID \(pid)"
        }
        if let windowId {
            if let title = windowInfo?.title, !title.isEmpty {
                return "window \(windowId) (\(title))"
            }
            return "window \(windowId)"
        }
        return "window"
    }
}

func windowTarget(from snapshot: UIAutomationSnapshot) -> WindowTarget? {
    if let windowID = snapshot.windowID {
        return .windowId(Int(windowID))
    }

    guard let applicationIdentifier = snapshot.applicationBundleId ?? snapshot.applicationName else {
        return nil
    }

    if let windowTitle = snapshot.windowTitle, !windowTitle.isEmpty {
        return .applicationAndTitle(app: applicationIdentifier, title: windowTitle)
    }
    return .application(applicationIdentifier)
}

func windowDisplayName(from snapshot: UIAutomationSnapshot, snapshotId: String) -> String {
    snapshot.applicationName ?? snapshot.applicationBundleId ?? "snapshot \(snapshotId)"
}

func createWindowActionResult(
    action: String,
    success: Bool,
    windowInfo: ServiceWindowInfo?,
    appName: String? = nil,
    requestedBounds: WindowBounds? = nil,
    warning: String? = nil
) -> WindowActionResult {
    let bounds: WindowBounds? = if let windowInfo {
        WindowBounds(
            x: Int(windowInfo.bounds.origin.x),
            y: Int(windowInfo.bounds.origin.y),
            width: Int(windowInfo.bounds.size.width),
            height: Int(windowInfo.bounds.size.height)
        )
    } else {
        nil
    }

    return WindowActionResult(
        action: action,
        success: success,
        app_name: appName ?? "Unknown",
        window_title: windowInfo?.title,
        new_bounds: bounds,
        requested_bounds: requestedBounds,
        warning: warning
    )
}

func logWindowAction(
    action: String,
    appName: String?,
    windowInfo: ServiceWindowInfo?
) {
    let title = windowInfo?.title ?? "Unknown"
    let boundsDescription: String
    if let windowBounds = windowInfo?.bounds {
        let origin = "bounds=(\(Int(windowBounds.origin.x)),\(Int(windowBounds.origin.y)))"
        let size = "x(\(Int(windowBounds.size.width)),\(Int(windowBounds.size.height)))"
        boundsDescription = "\(origin)\(size)"
    } else {
        boundsDescription = "bounds=unknown"
    }
    AutomationEventLogger.log(
        .window,
        "\(action) app=\(appName ?? "Unknown") title=\(title) \(boundsDescription)"
    )
}

@MainActor
func invalidateLatestSnapshotAfterWindowMutation(
    runtime: CommandRuntime,
    reason: String
) async {
    await InteractionObservationInvalidator.invalidateAfterMutation(
        targets: runtime.interactionMutationTargets,
        logger: runtime.logger,
        reason: reason
    )
}
