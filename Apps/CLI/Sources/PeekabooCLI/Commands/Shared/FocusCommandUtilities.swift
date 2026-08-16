import Commander
import CoreGraphics
import PeekabooCore
import PeekabooFoundation

enum FocusTargetRequest: Equatable {
    case windowId(CGWindowID)
    case bestWindow(applicationName: String, windowTitle: String?)
}

enum FocusTargetResolver {
    static func resolve(
        windowID: CGWindowID?,
        snapshot: UIAutomationSnapshot?,
        applicationName: String?,
        windowTitle: String?
    ) -> FocusTargetRequest? {
        self.resolve(
            windowID: windowID,
            snapshot: snapshot,
            windowContext: nil,
            applicationName: applicationName,
            windowTitle: windowTitle
        )
    }

    /// Resolve a focus target, falling back to the detection result's window context.
    ///
    /// Remote snapshot stores do not expose `UIAutomationSnapshot` over the bridge, so
    /// `snapshot` is nil there even for valid snapshots. Without the window-context fallback,
    /// `ensureFocused` silently resolved no target and `--foreground` never activated the app.
    static func resolve(
        windowID: CGWindowID?,
        snapshot: UIAutomationSnapshot?,
        windowContext: WindowContext?,
        applicationName: String?,
        windowTitle: String?
    ) -> FocusTargetRequest? {
        if let windowID {
            return .windowId(windowID)
        }

        if let snapshotWindowID = snapshot?.windowID {
            return .windowId(snapshotWindowID)
        }

        if let contextWindowID = windowContext?.windowID.flatMap(CGWindowID.init(exactly:)) {
            return .windowId(contextWindowID)
        }

        let resolvedApplicationName =
            applicationName
                ?? snapshot?.applicationBundleId ?? snapshot?.applicationName
                ?? windowContext?.applicationBundleId ?? windowContext?.applicationName
        let resolvedWindowTitle = windowTitle ?? snapshot?.windowTitle ?? windowContext?.windowTitle

        if let resolvedApplicationName {
            return .bestWindow(applicationName: resolvedApplicationName, windowTitle: resolvedWindowTitle)
        }

        return nil
    }
}

enum FocusFailurePolicy {
    static func optional<T>(_ operation: () async throws -> T) async throws -> T? {
        do {
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            return result
        } catch {
            try self.rethrowCancellation(error)
            return nil
        }
    }

    static func flatteningOptional<T>(_ operation: () async throws -> T?) async throws -> T? {
        do {
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            return result
        } catch {
            try self.rethrowCancellation(error)
            return nil
        }
    }

    static func rethrowCancellation(_ error: any Error) throws {
        if error is CancellationError {
            throw error
        }
        try Task.checkCancellation()
    }
}

typealias FocusResultProvider = @MainActor (
    CGWindowID,
    FocusManagementService.FocusOptions,
    WindowMutationIdentity
) async throws -> DesktopActionOutcome

@MainActor
private func performFocusResult(
    windowID: CGWindowID,
    options: FocusManagementService.FocusOptions,
    identity: WindowMutationIdentity,
    provider: FocusResultProvider?,
    focusService: FocusManagementActor
) async throws -> DesktopActionOutcome {
    if let provider {
        return try await provider(windowID, options, identity)
    }
    return try await focusService.focusWindowResult(
        windowID: windowID,
        options: options,
        expectedIdentity: identity
    )
}

struct PreparedFocusSelection {
    let target: WindowTarget
    let identity: WindowMutationIdentity
    let targetIdentity: DesktopTargetIdentity

    init(window: ServiceWindowInfo) throws {
        guard let identity = window.mutationIdentity,
              identity.windowID == window.windowID,
              let bounds = identity.capturedBounds,
              bounds == window.bounds
        else {
            throw PeekabooError.windowNotFound(
                criteria: "Focus target window \(window.windowID) has no consistent process-generation receipt"
            )
        }
        let exactWindow = try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
        self.target = .windowId(window.windowID)
        self.identity = identity
        self.targetIdentity = DesktopTargetIdentity(exactWindow: exactWindow)
    }

    init(target: WindowTarget, identity: WindowMutationIdentity, targetIdentity: DesktopTargetIdentity) {
        self.target = target
        self.identity = identity
        self.targetIdentity = targetIdentity
    }
}

@MainActor
private func prepareFocusSelection(
    target: WindowTarget,
    windows: any WindowManagementServiceProtocol,
    requireUniqueWindowTitle: Bool = false
) async throws -> PreparedFocusSelection {
    let matches = try await WindowServiceBridge.listWindows(
        windows: windows,
        target: target
    )
    if requireUniqueWindowTitle, matches.count != 1 {
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Foreground window-title targeting must resolve exactly one window.",
            hint: "Use a more specific title or select the window by ID after refreshing the window inventory."
        )
    }
    guard let selected = matches.first,
          let identity = selected.mutationIdentity,
          identity.windowID == selected.windowID,
          let bounds = identity.capturedBounds,
          bounds == selected.bounds
    else {
        throw PeekabooError.windowNotFound(
            criteria: "Focus target \(target) has no consistent process-generation receipt"
        )
    }
    let exactWindow = try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
    return PreparedFocusSelection(
        target: .windowId(selected.windowID),
        identity: identity,
        targetIdentity: DesktopTargetIdentity(exactWindow: exactWindow)
    )
}

@MainActor
private func prepareExplicitTitleSelection(
    windowTitle: String?,
    targetRequest: FocusTargetRequest?,
    windows: any WindowManagementServiceProtocol
) async throws -> PreparedFocusSelection? {
    guard windowTitle != nil,
          case let .bestWindow(applicationName, .some(resolvedWindowTitle)) = targetRequest
    else {
        return nil
    }
    return try await prepareFocusSelection(
        target: .applicationAndTitle(app: applicationName, title: resolvedWindowTitle),
        windows: windows,
        requireUniqueWindowTitle: true
    )
}

@MainActor
private func prepareExplicitTitleSelection(
    unless prepared: PreparedFocusSelection?,
    windowTitle: String?,
    targetRequest: FocusTargetRequest?,
    windows: any WindowManagementServiceProtocol
) async throws -> PreparedFocusSelection? {
    guard prepared == nil else { return nil }
    return try await prepareExplicitTitleSelection(
        windowTitle: windowTitle,
        targetRequest: targetRequest,
        windows: windows
    )
}

@MainActor
private func prepareFocusSelection(
    preferring prepared: PreparedFocusSelection?,
    target: WindowTarget,
    windows: any WindowManagementServiceProtocol
) async throws -> PreparedFocusSelection {
    if let prepared {
        return prepared
    }
    return try await prepareFocusSelection(target: target, windows: windows)
}

/// Ensure the target window is focused before executing a command.
@MainActor
@discardableResult
func ensureFocused(
    snapshotId: String? = nil,
    windowID: CGWindowID? = nil,
    applicationName: String? = nil,
    windowTitle: String? = nil,
    options: any FocusOptionsProtocol,
    services: any PeekabooServiceProviding,
    focusResultProvider: FocusResultProvider? = nil,
    preparedSelection: PreparedFocusSelection? = nil
) async throws -> UIAutomationActionResult<Void> {
    try Task.checkCancellation()
    guard options.autoFocus else {
        return UIAutomationActionResult(payload: (), outcome: nil)
    }

    let focusService = FocusManagementActor.shared

    let snapshot = if let snapshotId {
        try await services.snapshots.getUIAutomationSnapshot(snapshotId: snapshotId)
    } else {
        nil as UIAutomationSnapshot?
    }
    try Task.checkCancellation()

    // Remote snapshot stores return nil for getUIAutomationSnapshot; recover the focus target
    // from the detection result's window context so foreground focus still resolves.
    var windowContext: WindowContext?
    if snapshot == nil, let snapshotId {
        windowContext = await (try? services.snapshots.getDetectionResult(snapshotId: snapshotId))?
            .metadata.windowContext
        try Task.checkCancellation()
    }

    let targetRequest = FocusTargetResolver.resolve(
        windowID: windowID,
        snapshot: snapshot,
        windowContext: windowContext,
        applicationName: applicationName,
        windowTitle: windowTitle
    )
    let explicitTitleSelection = try await prepareExplicitTitleSelection(
        unless: preparedSelection,
        windowTitle: windowTitle,
        targetRequest: targetRequest,
        windows: services.windows
    )
    let retainedSelection = preparedSelection ?? explicitTitleSelection

    if services.executionHost == .remote {
        let selectionTarget: WindowTarget = switch targetRequest {
        case let .windowId(windowID):
            .windowId(Int(windowID))
        case let .bestWindow(applicationName, windowTitle):
            if let windowTitle {
                .applicationAndTitle(app: applicationName, title: windowTitle)
            } else {
                .application(applicationName)
            }
        case nil:
            throw PeekabooError.windowNotFound(
                criteria: "Remote foreground focus requires an exact resolvable window"
            )
        }
        let selection = try await prepareFocusSelection(
            preferring: retainedSelection,
            target: selectionTarget,
            windows: services.windows
        )
        return try await WindowServiceBridge.focusWindow(
            windows: services.windows,
            target: selection.target,
            expectedIdentity: selection.identity
        )
    }

    let targetWindow: CGWindowID? = if let retainedSelection {
        CGWindowID(exactly: retainedSelection.identity.windowID)
    } else {
        switch targetRequest {
        case let .windowId(windowID):
            windowID
        case let .bestWindow(applicationName, windowTitle):
            try await FocusFailurePolicy.flatteningOptional {
                try await focusService.findBestWindow(applicationName: applicationName, windowTitle: windowTitle)
            }
        case nil:
            nil
        }
    }

    guard let windowID = targetWindow else {
        if case let .bestWindow(applicationName, _) = targetRequest {
            let application = try await services.applications.findApplication(identifier: applicationName)
            try Task.checkCancellation()
            try await services.applications.activateApplication(
                request: ApplicationActivationRequest(application: application)
            )
            try Task.checkCancellation()
        }
        return UIAutomationActionResult(payload: (), outcome: nil)
    }

    let focusOptions = FocusManagementService.FocusOptions(
        timeout: options.focusTimeout ?? 5.0,
        retryCount: options.focusRetryCount ?? 3,
        switchSpace: options.spaceSwitch,
        bringToCurrentSpace: options.bringToCurrentSpace
    )

    try Task.checkCancellation()
    let selection = try await prepareFocusSelection(
        preferring: retainedSelection,
        target: .windowId(Int(windowID)),
        windows: services.windows
    )
    do {
        let outcome = try await performFocusResult(
            windowID: windowID,
            options: focusOptions,
            identity: selection.identity,
            provider: focusResultProvider,
            focusService: focusService
        )
        return UIAutomationActionResult(
            payload: (),
            outcome: outcome,
            targetIdentity: selection.targetIdentity
        )
    } catch let error as FocusError {
        switch error {
        case .windowNotFound, .axElementNotFound:
            var fallbackErrors: [any Error] = []
            for target in [WindowTarget.windowId(Int(windowID))] {
                try Task.checkCancellation()
                do {
                    return try await WindowServiceBridge.focusWindow(
                        windows: services.windows,
                        target: target,
                        expectedIdentity: selection.identity
                    )
                } catch {
                    try FocusFailurePolicy.rethrowCancellation(error)
                    fallbackErrors.append(error)
                }
            }

            throw fallbackErrors.last ?? error
        default:
            throw error
        }
    }
}

/// Focus a window that was already resolved and generation-pinned by the caller.
@MainActor
@discardableResult
func ensureFocused(
    preparedWindow: ServiceWindowInfo,
    applicationName: String? = nil,
    windowTitle: String? = nil,
    options: any FocusOptionsProtocol,
    services: any PeekabooServiceProviding,
    focusResultProvider: FocusResultProvider? = nil
) async throws -> UIAutomationActionResult<Void> {
    let selection = try PreparedFocusSelection(window: preparedWindow)
    guard let windowID = CGWindowID(exactly: preparedWindow.windowID) else {
        throw PeekabooError.windowNotFound(criteria: "Focus target has an invalid WindowServer identifier")
    }
    return try await ensureFocused(
        windowID: windowID,
        applicationName: applicationName,
        windowTitle: windowTitle,
        options: options,
        services: services,
        focusResultProvider: focusResultProvider,
        preparedSelection: selection
    )
}

/// Ensure focus using shared interaction target flags (`--app/--pid/--window-title/--window-index`).
@MainActor
@discardableResult
func ensureFocused(
    snapshotId: String? = nil,
    target: InteractionTargetOptions,
    options: any FocusOptionsProtocol,
    services: any PeekabooServiceProviding
) async throws -> UIAutomationActionResult<Void> {
    let windowID = try await target.resolveWindowID(services: services)
    let appIdentifier = try target.resolveApplicationIdentifierOptional()
    return try await ensureFocused(
        snapshotId: snapshotId,
        windowID: windowID,
        applicationName: appIdentifier,
        windowTitle: target.windowTitle,
        options: options,
        services: services
    )
}

/// Resolves and confirms one exact foreground focus before a command is allowed to send global input.
/// A genuinely targetless foreground command bypasses setup focus and remains explicitly global.
@MainActor
func ensureConfirmedForegroundFocus(
    snapshotId: String?,
    target: InteractionTargetOptions,
    options: any FocusOptionsProtocol,
    services: any PeekabooServiceProviding,
    operation: String
) async throws -> UIAutomationActionResult<Void>? {
    let requiresTargetedFocus = target.hasAnyTarget || snapshotId != nil
    guard requiresTargetedFocus else { return nil }
    guard options.autoFocus else {
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .invalidRequest,
            message: "\(operation) has a target but automatic foreground focus is disabled.",
            hint: "Remove the target for intentional global input, or allow Peekaboo to focus the exact target."
        )
    }

    let result = try await ensureFocused(
        snapshotId: snapshotId,
        target: target,
        options: options,
        services: services
    )
    return try validatedConfirmedForegroundFocusResult(result, operation: operation)
}

func validatedConfirmedForegroundFocusResult(
    _ result: UIAutomationActionResult<Void>,
    operation: String
) throws -> UIAutomationActionResult<Void> {
    let targetReceipt = result.targetIdentity.flatMap(focusTargetReceipt)
    guard let targetIdentity = result.targetIdentity,
          targetIdentity.exactWindow != nil
    else {
        throw DesktopActionFailure.indeterminate(
            route: result.outcome?.route ?? .local,
            delivery: result.outcome?.delivery,
            evidence: .completionUnknown,
            unitCount: result.outcome?.dispatchState.unitCount,
            message: "\(operation) returned without an exact focused-window identity.",
            hint: "Observe the target before retrying and update the runtime host."
        ).attributed(to: targetReceipt)
    }
    guard let outcome = result.outcome else {
        throw DesktopActionFailure.indeterminate(
            evidence: .completionUnknown,
            message: "\(operation) returned without a canonical focus outcome.",
            hint: "Observe the target before retrying and update the runtime host."
        ).attributed(to: focusTargetReceipt(targetIdentity))
    }
    guard outcome.isConfirmed else {
        guard let failure = DesktopActionFailure(
            outcome: outcome,
            message: "\(operation) did not confirm exact foreground focus.",
            hint: "Do not send global input until the exact target focus is confirmed.",
            targetReceipt: focusTargetReceipt(targetIdentity)
        ) else {
            preconditionFailure("A non-confirmed focus outcome must construct a failure")
        }
        throw failure
    }
    if outcome.dispatchState.mutationDispatched,
       outcome.delivery?.mode != .foreground {
        throw DesktopActionFailure.indeterminate(
            route: outcome.route,
            delivery: outcome.delivery,
            evidence: .completionUnknown,
            unitCount: outcome.dispatchState.unitCount,
            message: "\(operation) confirmed a dispatched focus without foreground delivery.",
            hint: "Do not send global input until the exact target focus is confirmed in the foreground."
        ).attributed(to: focusTargetReceipt(targetIdentity))
    }
    return result
}

private func focusTargetReceipt(_ identity: DesktopTargetIdentity) -> DesktopActionTargetReceipt {
    identity.actionTargetReceipt
}

@MainActor
final class FocusManagementActor {
    static let shared = FocusManagementActor()

    private let inner = FocusManagementService()

    func findBestWindow(applicationName: String, windowTitle: String?) async throws -> CGWindowID? {
        try await self.inner.findBestWindow(applicationName: applicationName, windowTitle: windowTitle)
    }

    func focusWindowResult(
        windowID: CGWindowID,
        options: FocusManagementService.FocusOptions,
        expectedIdentity: WindowMutationIdentity? = nil
    ) async throws -> DesktopActionOutcome {
        try await self.inner.focusWindowResult(
            windowID: windowID,
            options: options,
            expectedIdentity: expectedIdentity
        )
    }
}
