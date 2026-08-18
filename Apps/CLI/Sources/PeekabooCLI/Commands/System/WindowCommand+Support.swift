import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

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

    var selector: InteractionTargetSelector {
        InteractionTargetSelector(
            applicationIdentifier: self.app,
            processIdentifier: self.pid.map(Int.init),
            windowID: self.windowId,
            windowTitle: self.windowTitle,
            windowIndex: self.windowIndex
        )
    }

    func validate(allowMissingTarget: Bool = false) throws {
        do {
            try self.selector.validate(policy: .windowCLI(allowMissingTarget: allowMissingTarget))
        } catch let error as InteractionTargetSelector.ValidationError {
            switch error {
            case .invalidWindowID:
                throw ValidationError("--window-id must be greater than 0")
            case .missingTarget:
                throw ValidationError("Either --app, --pid, or --window-id must be specified")
            case .invalidWindowIndex:
                throw ValidationError("--window-index must be 0 or greater")
            case let .conflictingProcessIdentifiers(applicationPID, explicitPID):
                throw PeekabooError.invalidInput(
                    "Conflicting PIDs: --app specifies PID \(applicationPID) but --pid is \(explicitPID)"
                )
            case .invalidApplicationProcessIdentifier:
                throw PeekabooError.invalidInput("Invalid PID format in --app: '\(self.app ?? "")'")
            case .applicationAndProcessIdentifier:
                throw PeekabooError.invalidInput("Provide the application either with --app or --pid, not both")
            case .multipleWindowSelectors,
                 .windowSelectorRequiresApplication,
                 .invalidProcessIdentifier,
                 .emptyApplication,
                 .emptyWindowTitle:
                preconditionFailure("Window CLI policy does not emit \(error)")
            }
        }
    }

    /// Validate selectors used to choose a window for mutation. Unlike the compatibility grammar,
    /// this rejects redundant owner channels and selector precedence before inventory lookup.
    func validateMutation(allowMissingTarget: Bool = false) throws {
        _ = try validatedMutationSelector(self.selector, allowMissingTarget: allowMissingTarget)
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

    /// Resolve the full owner inventory used to pin an exact mutation receipt. Pre-filtering by a
    /// title or index would hide ambiguity before the strict selector resolver can reject it.
    func toWindowSelectionTarget() throws -> WindowTarget {
        if self.app != nil || self.pid != nil {
            return try .application(self.resolveApplicationIdentifier())
        }
        return try self.toWindowTarget()
    }

    func requireMutationWindow(
        from windows: [ServiceWindowInfo],
        expectedApplication: ServiceApplicationInfo?,
        action: String
    ) throws -> ServiceWindowInfo {
        let window: ServiceWindowInfo
        do {
            window = try self.selectMutationWindow(from: windows, operation: "Window \(action)")
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: error.localizedDescription,
                hint: "Refresh the window inventory and select one exact --window-id.",
                causeDescription: String(describing: error)
            )
        }
        if let expectedApplication {
            guard let expectedProcessStartIdentity = expectedApplication.processStartIdentity,
                  let identity = window.mutationIdentity,
                  identity.ownerProcessIdentifier == expectedApplication.processIdentifier,
                  identity.ownerProcessStartIdentity == expectedProcessStartIdentity
            else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Window \(window.windowID) is not owned by the selected application process.",
                    hint: "Refresh the application and window inventories before retrying."
                )
            }
        }
        guard let identity = window.mutationIdentity,
              let capturedBounds = identity.capturedBounds,
              capturedBounds == window.bounds
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Window \(window.windowID) has inconsistent bounds provenance.",
                hint: "Refresh the window inventory before retrying."
            )
        }
        return window
    }
}

func validatedPostMutationWindowReadback(
    _ window: ServiceWindowInfo,
    expectedIdentity: WindowMutationIdentity,
    operation: String
) throws -> ServiceWindowInfo {
    guard window.windowID == expectedIdentity.windowID,
          let returnedIdentity = window.mutationIdentity,
          returnedIdentity.windowID == expectedIdentity.windowID,
          returnedIdentity.ownerProcessIdentifier == expectedIdentity.ownerProcessIdentifier,
          returnedIdentity.ownerProcessStartIdentity == expectedIdentity.ownerProcessStartIdentity,
          let returnedBounds = returnedIdentity.capturedBounds,
          returnedBounds == window.bounds
    else {
        throw PeekabooError.windowNotFound(
            criteria: "\(operation) readback no longer matches the original exact-window receipt"
        )
    }
    return window
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
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            applications: services.applications
        )
        return try await planner.plan(identifier: identifier).application
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
