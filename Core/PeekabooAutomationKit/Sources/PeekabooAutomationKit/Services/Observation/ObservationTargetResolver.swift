import CoreGraphics
import Foundation

@MainActor
public protocol ObservationTargetResolving: Sendable {
    func resolve(
        _ target: DesktopObservationTargetRequest,
        snapshot: DesktopStateSnapshot) async throws -> ResolvedObservationTarget
}

@MainActor
public final class ObservationTargetResolver: ObservationTargetResolving {
    private let applications: any ApplicationServiceProtocol
    let menu: (any MenuServiceProtocol)?
    let screens: (any ScreenServiceProtocol)?

    public init(
        applications: any ApplicationServiceProtocol,
        menu: (any MenuServiceProtocol)? = nil,
        screens: (any ScreenServiceProtocol)? = nil)
    {
        self.applications = applications
        self.menu = menu
        self.screens = screens
    }

    public func resolve(
        _ target: DesktopObservationTargetRequest,
        snapshot: DesktopStateSnapshot) async throws -> ResolvedObservationTarget
    {
        switch target {
        case let .screen(index):
            ResolvedObservationTarget(kind: .screen(index: index))

        case .allScreens:
            ResolvedObservationTarget(kind: .screen(index: nil))

        case .frontmost:
            try await self.resolveFrontmost(snapshot: snapshot)

        case let .app(identifier, selection):
            try await self.resolveApplication(identifier: identifier, selection: selection, snapshot: snapshot)

        case let .pid(pid, selection):
            try await self.resolvePID(pid, selection: selection, snapshot: snapshot)

        case let .windowID(windowID):
            self.resolveWindowID(windowID)

        case let .area(rect):
            ResolvedObservationTarget(kind: .area(rect), bounds: rect)

        case .menubar:
            try self.resolveMenuBar()

        case let .menubarPopover(hints, openIfNeeded):
            try await self.resolveMenuBarPopover(hints: hints, openIfNeeded: openIfNeeded)
        }
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
        let app: ServiceApplicationInfo? = if let snapshotApp = snapshot.runningApplications
            .first(where: { $0.processIdentifier == pid })
        {
            Self.serviceApplicationInfo(from: snapshotApp)
        } else {
            try await self.fallbackApplication(pid: pid)
        }

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
        let app: ServiceApplicationInfo = if let snapshotApp = Self.application(
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
        let lookupIdentifier = app.bundleIdentifier ?? app.name
        let windows = try await self.applications.listWindows(for: lookupIdentifier, timeout: 2).data.windows
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
            windowBounds: selectedWindow?.bounds)

        return ResolvedObservationTarget(
            kind: selectedWindow.map { .windowID(CGWindowID($0.windowID)) } ?? .appWindow,
            app: ApplicationIdentity(app),
            window: selectedWindow.map(WindowIdentity.init),
            bounds: selectedWindow?.bounds,
            detectionContext: context)
    }

    private func fallbackApplication(pid: Int32) async throws -> ServiceApplicationInfo? {
        let applications = try await self.applications.listApplications().data.applications
        return applications.first(where: { $0.processIdentifier == pid })
    }

    private static func application(
        matching identifier: String,
        in applications: [ApplicationIdentity]) -> ApplicationIdentity?
    {
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercasedIdentifier = trimmedIdentifier.uppercased()
        if uppercasedIdentifier.hasPrefix("PID:"),
           let pid = Int32(trimmedIdentifier.dropFirst("PID:".count)),
           let match = applications.first(where: { $0.processIdentifier == pid })
        {
            return match
        }

        if let bundleMatch = applications.first(where: { $0.bundleIdentifier == trimmedIdentifier }) {
            return bundleMatch
        }

        if let exactName = applications.first(where: {
            $0.name.compare(trimmedIdentifier, options: .caseInsensitive) == .orderedSame
        }) {
            return exactName
        }

        return applications.first(where: {
            $0.name.localizedCaseInsensitiveContains(trimmedIdentifier)
        })
    }

    private static func serviceApplicationInfo(from identity: ApplicationIdentity) -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: identity.processIdentifier,
            bundleIdentifier: identity.bundleIdentifier,
            name: identity.name,
            windowCount: 0)
    }
}
