import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
public protocol ObservationTargetResolving: Sendable {
    func resolve(
        _ target: DesktopObservationTargetRequest,
        snapshot: DesktopStateSnapshot) async throws -> ResolvedObservationTarget

    func resolveActionResult(
        _ target: DesktopObservationTargetRequest,
        snapshot: DesktopStateSnapshot) async throws -> UIAutomationActionResult<ResolvedObservationTarget>
}

extension ObservationTargetResolving {
    public func resolveActionResult(
        _ target: DesktopObservationTargetRequest,
        snapshot: DesktopStateSnapshot) async throws -> UIAutomationActionResult<ResolvedObservationTarget>
    {
        try await UIAutomationActionResult(payload: self.resolve(target, snapshot: snapshot), outcome: nil)
    }
}

@MainActor
public final class ObservationTargetResolver: ObservationTargetResolving {
    private let applications: any ApplicationServiceProtocol
    let menu: (any MenuServiceProtocol)?
    let screens: (any ScreenServiceProtocol)?
    let exactWindowMetadataProvider: any ExactWindowMetadataProviding

    public init(
        applications: any ApplicationServiceProtocol,
        menu: (any MenuServiceProtocol)? = nil,
        screens: (any ScreenServiceProtocol)? = nil,
        exactWindowMetadataProvider: any ExactWindowMetadataProviding = SystemExactWindowMetadataProvider())
    {
        self.applications = applications
        self.menu = menu
        self.screens = screens
        self.exactWindowMetadataProvider = exactWindowMetadataProvider
    }

    public func resolve(
        _ target: DesktopObservationTargetRequest,
        snapshot: DesktopStateSnapshot) async throws -> ResolvedObservationTarget
    {
        try await self.resolveActionResult(target, snapshot: snapshot).payload
    }

    public func resolveActionResult(
        _ target: DesktopObservationTargetRequest,
        snapshot: DesktopStateSnapshot) async throws -> UIAutomationActionResult<ResolvedObservationTarget>
    {
        if case let .menubarPopover(hints, openIfNeeded) = target {
            return try await self.resolveMenuBarPopoverActionResult(
                hints: hints,
                openIfNeeded: openIfNeeded)
        }
        let resolved: ResolvedObservationTarget = switch target {
        case let .screen(index):
            ResolvedObservationTarget(kind: .screen(index: index))

        case .allScreens:
            throw DesktopObservationError.allScreensRequiresMultiArtifactOutput

        case .frontmost:
            try await self.resolveFrontmost(snapshot: snapshot)

        case let .app(identifier, selection):
            try await self.resolveApplication(identifier: identifier, selection: selection, snapshot: snapshot)

        case let .pid(pid, selection):
            try await self.resolvePID(pid, selection: selection, snapshot: snapshot)

        case let .windowID(windowID):
            try self.resolveWindowID(windowID)

        case let .area(rect):
            ResolvedObservationTarget(kind: .area(rect), bounds: rect)

        case .menubar:
            try self.resolveMenuBar()

        case .menubarPopover:
            preconditionFailure("Menu-bar popovers are handled by their action-result resolver")
        }
        return UIAutomationActionResult(payload: resolved, outcome: nil)
    }

    private func resolveFrontmost(snapshot: DesktopStateSnapshot) async throws -> ResolvedObservationTarget {
        let app = if let frontmost = snapshot.frontmostApplication {
            Self.serviceApplicationInfo(from: frontmost)
        } else {
            try await self.applications.getFrontmostApplication()
        }
        return try await self.resolveApplication(app, selection: .automatic)
    }

    private func resolvePID(
        _ pid: Int32,
        selection: WindowSelection?,
        snapshot: DesktopStateSnapshot) async throws -> ResolvedObservationTarget
    {
        if let snapshotApp = snapshot.runningApplications.first(where: { $0.processIdentifier == pid }) {
            return try await self.resolveApplication(
                Self.serviceApplicationInfo(from: snapshotApp),
                selection: selection ?? .automatic)
        }
        if case let .id(windowID)? = selection,
           let exact = try self.resolveExactWindowIfAvailable(windowID, expectedPID: pid)
        {
            return exact
        }

        let app = try await self.fallbackApplication(pid: pid)
        guard let app else {
            throw DesktopObservationError.targetNotFound("pid \(pid)")
        }
        return try await self.resolveApplication(app, selection: selection ?? .automatic)
    }

    private func resolveApplication(
        identifier: String,
        selection: WindowSelection?,
        snapshot: DesktopStateSnapshot) async throws -> ResolvedObservationTarget
    {
        let app: ServiceApplicationInfo = if let snapshotApp = try Self.application(
            matching: identifier,
            in: snapshot.runningApplications)
        {
            Self.serviceApplicationInfo(from: snapshotApp)
        } else {
            try await self.applications.findApplication(identifier: identifier)
        }
        return try await self.resolveApplication(app, selection: selection ?? .automatic)
    }

    private func resolveApplication(
        _ app: ServiceApplicationInfo,
        selection: WindowSelection) async throws -> ResolvedObservationTarget
    {
        if app.processStartIdentity == nil {
            return try await self.resolveLegacyReadOnlyApplication(app, selection: selection)
        }

        if case let .id(windowID) = selection {
            return try self.resolveExactWindow(windowID, for: app)
        }

        let usesWindowServerCatalog = switch selection {
        case .automatic, .title:
            true
        case .id, .index:
            false
        }
        if usesWindowServerCatalog {
            let catalogIdentities = self.exactWindowMetadataProvider.windows(for: app.processIdentifier)
            if !catalogIdentities.isEmpty {
                guard let processStartIdentity = app.processStartIdentity,
                      self.exactWindowMetadataProvider.processStartIdentity(for: app.processIdentifier) ==
                      processStartIdentity
                else {
                    throw DesktopObservationError.targetNotFound(
                        "live process generation for PID \(app.processIdentifier)")
                }
            }
            let processStartIdentity = app.processStartIdentity
            let catalogWindows = catalogIdentities
                .filter {
                    $0.ownerProcessIdentifier == app.processIdentifier &&
                        $0.ownerProcessStartIdentity == processStartIdentity
                }
                .enumerated()
                .map { index, identity in Self.serviceWindowInfo(identity, index: index) }
            let hasRequestedTitle: Bool = switch selection {
            case .automatic:
                true
            case let .title(title):
                catalogWindows.contains { $0.title.localizedCaseInsensitiveContains(title) }
            case .id, .index:
                false
            }
            if !catalogWindows.isEmpty, hasRequestedTitle {
                let resolved = try self.resolveApplication(app, selection: selection, windows: catalogWindows)
                guard let selectedWindowID = resolved.window?.windowID,
                      let exactWindowID = CGWindowID(exactly: selectedWindowID)
                else {
                    return resolved
                }
                return try self.resolveExactWindow(
                    exactWindowID,
                    for: app,
                    selectorResolutionProofs: resolved.selectorResolutionProofs)
            }
        }

        let lookupIdentifier = app.bundleIdentifier ?? app.name
        let windows = try await self.applications.listWindows(for: lookupIdentifier, timeout: 2).data.windows
        return try self.resolveApplication(app, selection: selection, windows: windows)
    }

    private func resolveLegacyReadOnlyApplication(
        _ app: ServiceApplicationInfo,
        selection: WindowSelection) async throws -> ResolvedObservationTarget
    {
        let lookupIdentifier = app.bundleIdentifier ?? app.name
        let windows = try await self.applications.listWindows(for: lookupIdentifier, timeout: 2).data.windows
            .map(Self.readOnlyWindowInfo)
        return try self.resolveApplication(app, selection: selection, windows: windows)
    }

    private func resolveApplication(
        _ app: ServiceApplicationInfo,
        selection: WindowSelection,
        windows: [ServiceWindowInfo]) throws -> ResolvedObservationTarget
    {
        let selectedWindow = try self.selectWindow(from: windows, selection: selection)
        if selection == .automatic, selectedWindow == nil, !windows.isEmpty {
            throw DesktopObservationError.targetNotFound(
                "shareable window for \(app.name). Candidates: "
                    + Self.captureCandidateSummary(from: windows))
        }
        let context = WindowContext(
            applicationName: app.name,
            applicationBundleId: app.bundleIdentifier,
            applicationProcessId: app.processIdentifier,
            windowTitle: selectedWindow?.title,
            windowID: selectedWindow?.windowID,
            windowBounds: selectedWindow?.bounds,
            windowMutationIdentity: selectedWindow?.mutationIdentity)
        var selectorResolutionProofs = app.selectorResolutionProofs?.map {
            $0.selecting(windowIdentity: selectedWindow?.mutationIdentity)
        }
        if let selectedWindow, let processIdentity = app.processIdentity {
            let windowProof = try WindowSelectorResolutionProof.make(
                selection: selection,
                candidates: windows,
                selected: selectedWindow,
                processIdentity: processIdentity)
            selectorResolutionProofs = (selectorResolutionProofs ?? []) + [windowProof]
        }

        return ResolvedObservationTarget(
            kind: selectedWindow.map { .windowID(CGWindowID($0.windowID)) } ?? .appWindow,
            app: ApplicationIdentity(app),
            window: selectedWindow.map(WindowIdentity.init),
            bounds: selectedWindow?.bounds,
            detectionContext: context,
            selectorResolutionProofs: selectorResolutionProofs)
    }

    nonisolated static func serviceWindowInfo(
        _ identity: SystemWindowIdentity,
        index: Int) -> ServiceWindowInfo
    {
        ServiceWindowInfo(
            windowID: Int(identity.windowID),
            title: identity.title,
            bounds: identity.bounds,
            isMinimized: !identity.isOnScreen,
            isMainWindow: false,
            windowLevel: identity.layer,
            alpha: identity.alpha,
            index: index,
            isOffScreen: !identity.isOnScreen,
            layer: identity.layer,
            isOnScreen: identity.isOnScreen,
            sharingState: identity.sharingState,
            isExcludedFromWindowsMenu: false,
            mutationIdentity: identity.ownerProcessStartIdentity.map {
                WindowMutationIdentity(
                    windowID: Int(identity.windowID),
                    ownerProcessIdentifier: identity.ownerProcessIdentifier,
                    ownerProcessStartIdentity: $0,
                    capturedBounds: identity.bounds,
                    isMinimized: !identity.isOnScreen)
            })
    }

    private nonisolated static func readOnlyWindowInfo(_ window: ServiceWindowInfo) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: window.windowID,
            title: window.title,
            bounds: window.bounds,
            isMinimized: window.isMinimized,
            isMainWindow: window.isMainWindow,
            isKeyWindow: window.isKeyWindow,
            isFrontmost: window.isFrontmost,
            subrole: window.subrole,
            windowLevel: window.windowLevel,
            alpha: window.alpha,
            index: window.index,
            spaceID: window.spaceID,
            spaceName: window.spaceName,
            screenIndex: window.screenIndex,
            screenName: window.screenName,
            isOffScreen: window.isOffScreen,
            layer: window.layer,
            isOnScreen: window.isOnScreen,
            sharingState: window.sharingState,
            isExcludedFromWindowsMenu: window.isExcludedFromWindowsMenu,
            mutationIdentity: nil)
    }

    private func resolveExactWindow(
        _ windowID: CGWindowID,
        for app: ServiceApplicationInfo,
        selectorResolutionProofs: [SelectorResolutionProof]? = nil) throws -> ResolvedObservationTarget
    {
        guard let metadata = self.exactWindowMetadataProvider.metadata(for: windowID),
              let processStartIdentity = app.processStartIdentity,
              metadata.ownerProcessIdentifier == app.processIdentifier,
              metadata.ownerProcessStartIdentity == processStartIdentity,
              self.exactWindowMetadataProvider.processStartIdentity(for: app.processIdentifier) ==
              processStartIdentity
        else {
            throw DesktopObservationError.targetNotFound(
                "window id \(windowID) owned by PID \(app.processIdentifier)")
        }

        return Self.resolvedExactWindow(
            windowID,
            app: app,
            metadata: metadata,
            selectorResolutionProofs: selectorResolutionProofs)
    }

    private func resolveExactWindowIfAvailable(
        _ windowID: CGWindowID,
        expectedPID: Int32) throws -> ResolvedObservationTarget?
    {
        guard let metadata = self.exactWindowMetadataProvider.metadata(for: windowID) else {
            return nil
        }
        guard metadata.ownerProcessIdentifier == expectedPID else {
            throw DesktopObservationError.targetNotFound(
                "window id \(windowID) owned by PID \(expectedPID)")
        }
        guard let liveProcessStartIdentity = self.exactWindowMetadataProvider.processStartIdentity(for: expectedPID)
        else {
            return nil
        }
        guard liveProcessStartIdentity == metadata.ownerProcessStartIdentity else {
            throw DesktopObservationError.targetNotFound(
                "live process generation for PID \(expectedPID)")
        }
        let app = ServiceApplicationInfo(
            processIdentifier: expectedPID,
            processStartIdentity: metadata.ownerProcessStartIdentity,
            bundleIdentifier: nil,
            name: metadata.applicationName ?? "PID:\(expectedPID)",
            windowCount: 1)
        return Self.resolvedExactWindow(windowID, app: app, metadata: metadata)
    }

    private static func resolvedExactWindow(
        _ windowID: CGWindowID,
        app: ServiceApplicationInfo,
        metadata: ExactWindowObservationMetadata,
        selectorResolutionProofs: [SelectorResolutionProof]? = nil) -> ResolvedObservationTarget
    {
        let window = WindowIdentity(
            windowID: Int(windowID),
            title: metadata.title,
            bounds: metadata.bounds,
            index: 0)
        let windowIdentity = WindowMutationIdentity(
            windowID: window.windowID,
            ownerProcessIdentifier: metadata.ownerProcessIdentifier,
            ownerProcessStartIdentity: metadata.ownerProcessStartIdentity,
            capturedBounds: window.bounds)
        let context = WindowContext(
            applicationName: app.name,
            applicationBundleId: app.bundleIdentifier,
            applicationProcessId: app.processIdentifier,
            windowTitle: window.title,
            windowID: window.windowID,
            windowBounds: window.bounds,
            windowMutationIdentity: windowIdentity)
        let proofs = selectorResolutionProofs ?? app.selectorResolutionProofs?.map {
            $0.selecting(windowIdentity: windowIdentity)
        }
        return ResolvedObservationTarget(
            kind: .windowID(windowID),
            app: ApplicationIdentity(app),
            window: window,
            bounds: window.bounds,
            detectionContext: context,
            selectorResolutionProofs: proofs)
    }

    private func fallbackApplication(pid: Int32) async throws -> ServiceApplicationInfo? {
        let applications = try await self.applications.listApplications().data.applications
        return applications.first(where: { $0.processIdentifier == pid })
    }

    private static func application(
        matching identifier: String,
        in applications: [ApplicationIdentity]) throws -> ApplicationIdentity?
    {
        let candidates = applications.map(ApplicationIdentifierMatcher.Candidate.init)
        guard let resolution = try ApplicationIdentifierMatcher.resolution(for: identifier, in: candidates) else {
            return nil
        }
        guard !resolution.hasWinningTie else {
            throw PeekabooError.ambiguousAppIdentifier(
                identifier,
                suggestions: candidates.map(\.name))
        }
        let application = applications[resolution.index]
        let proof = application.processStartIdentity.map {
            resolution.proof(selectedProcessIdentity: ApplicationProcessIdentity(
                processIdentifier: application.processIdentifier,
                processStartIdentity: $0))
        }
        return application.withSelectorResolutionProofs(proof.map { [$0] })
    }

    private static func serviceApplicationInfo(from identity: ApplicationIdentity) -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: identity.processIdentifier,
            processStartIdentity: identity.processStartIdentity,
            bundleIdentifier: identity.bundleIdentifier,
            name: identity.name,
            bundlePath: identity.bundlePath,
            executablePath: identity.executablePath,
            windowCount: 0,
            activationPolicy: identity.activationPolicy,
            selectorResolutionProofs: identity.selectorResolutionProofs)
    }
}

extension DesktopObservationError {
    static var allScreensRequiresMultiArtifactOutput: Self {
        .unsupportedTarget("all screens require multi-artifact output")
    }
}
