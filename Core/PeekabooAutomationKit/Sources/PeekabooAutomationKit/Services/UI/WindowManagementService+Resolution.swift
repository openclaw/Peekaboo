import AppKit
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
extension WindowManagementService {
    func pinnedWindowMutation(
        for target: WindowTarget) async throws -> (target: WindowTarget, identity: WindowMutationIdentity)
    {
        let windows = try await self.listWindows(target: target)
        guard let window = windows.first else {
            throw PeekabooError.windowNotFound(criteria: "No window matched \(target)")
        }
        guard let identity = window.mutationIdentity else {
            throw PeekabooError.commandFailed(
                "Could not capture process-generation identity for window \(window.windowID)")
        }
        try self.validatePinnedWindowMutation(target: .windowId(window.windowID), expectedIdentity: identity)
        return (.windowId(window.windowID), identity)
    }

    func validatePinnedWindowMutation(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) throws
    {
        guard case let .windowId(windowID) = target, windowID == expectedIdentity.windowID else {
            throw PeekabooError.invalidInput(
                "Pinned window mutation target does not match identity window \(expectedIdentity.windowID)")
        }
        guard expectedIdentity.capturedBounds != nil else {
            throw PeekabooError.commandFailed(
                "Window \(expectedIdentity.windowID) mutation receipt lacks capture-time bounds")
        }
        if SystemIdentityResolver.validateWindowMutationIdentity(expectedIdentity) {
            return
        }
        // WindowServer can omit minimized entries. This only admits the operation to a bounded AX
        // resolution step; the retained AX element must still match the receipt bounds before dispatch.
        let currentWindow = CGWindowID(exactly: expectedIdentity.windowID)
            .flatMap(SystemIdentityResolver.windowIdentity)
        guard currentWindow == nil,
              expectedIdentity.isMinimized == true,
              SystemIdentityResolver.validateWindowMutationOwnerGeneration(expectedIdentity)
        else {
            throw PeekabooError.commandFailed(
                "Window \(expectedIdentity.windowID) disappeared or changed identity")
        }
    }

    func validatePinnedWindowElement(
        _ window: Element,
        expectedIdentity: WindowMutationIdentity) throws
    {
        guard let capturedBounds = expectedIdentity.capturedBounds,
              SystemIdentityResolver.validateWindowMutationOwnerGeneration(expectedIdentity),
              self.windowIdentityService.getWindowID(from: window).map(Int.init) == expectedIdentity.windowID,
              let position = window.position(),
              let size = window.size(),
              CGRect(origin: position, size: size) == capturedBounds
        else {
            throw PeekabooError.commandFailed(
                "Window \(expectedIdentity.windowID) changed identity before native dispatch")
        }
    }

    func waitForRepinnedWindowMutation(
        _ expectedIdentity: WindowMutationIdentity,
        expectedBounds: CGRect,
        timeout: Duration = .seconds(2)) async throws -> WindowMutationIdentity
    {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let repinned = SystemIdentityResolver.repinWindowMutationIdentity(
                expectedIdentity,
                expectedBounds: expectedBounds)
            {
                return repinned
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PeekabooError.commandFailed(
            "Window \(expectedIdentity.windowID) did not reach verified requested bounds \(expectedBounds)")
    }

    func windows(for appIdentifier: String) async throws -> [ServiceWindowInfo] {
        let output = try await self.applicationService.listWindows(for: appIdentifier, timeout: nil)
        return output.data.windows
    }

    func windowsWithTitleSubstring(_ substring: String) async throws -> [ServiceWindowInfo] {
        let appsOutput = try await self.applicationService.listApplications()
        var matches: [ServiceWindowInfo] = []

        for app in appsOutput.data.applications
            where app.isUsableForBroadAutomationDiscovery
        {
            let windows = try await self.windows(for: app.name)
            matches.append(contentsOf: windows.filter {
                $0.title.localizedCaseInsensitiveContains(substring)
            })
        }
        return matches
    }

    func windowById(_ id: Int) async throws -> [ServiceWindowInfo] {
        if let windowInfo = self.cgInfoLookup.serviceWindowInfo(windowID: id) {
            if !windowInfo.isOnScreen, let originalIdentity = windowInfo.mutationIdentity {
                let ownerPID = originalIdentity.ownerProcessIdentifier
                if let snapshot = await Task.detached(priority: .userInitiated, operation: {
                    BoundedAXWindowIdentityScanner.find(
                        windowID: id,
                        processIdentifiers: [ownerPID],
                        timeout: 1)
                }).value,
                    snapshot.windowID == id,
                    snapshot.ownerProcessIdentifier == ownerPID,
                    snapshot.ownerProcessStartIdentity == originalIdentity.ownerProcessStartIdentity,
                    SystemIdentityResolver.processStartIdentity(ownerPID) == snapshot.ownerProcessStartIdentity
                {
                    return [windowInfo.withExactAXState(
                        title: snapshot.title,
                        bounds: snapshot.bounds,
                        isMinimized: snapshot.isMinimized)]
                }
            }
            return [windowInfo]
        }

        let processIdentifiers = NSWorkspace.shared.runningApplications.compactMap { application -> pid_t? in
            application.isTerminated ? nil : application.processIdentifier
        }
        if let snapshot = await Task.detached(priority: .userInitiated, operation: {
            BoundedAXWindowIdentityScanner.find(
                windowID: id,
                processIdentifiers: processIdentifiers,
                timeout: 2)
        }).value,
            snapshot.windowID == id,
            SystemIdentityResolver.processStartIdentity(snapshot.ownerProcessIdentifier) ==
            snapshot.ownerProcessStartIdentity
        {
            let identity = WindowMutationIdentity(
                windowID: id,
                ownerProcessIdentifier: snapshot.ownerProcessIdentifier,
                ownerProcessStartIdentity: snapshot.ownerProcessStartIdentity,
                capturedBounds: snapshot.bounds,
                isMinimized: snapshot.isMinimized)
            return [ServiceWindowInfo(
                windowID: id,
                title: snapshot.title,
                bounds: snapshot.bounds,
                isMinimized: snapshot.isMinimized,
                isMainWindow: false,
                windowLevel: 0,
                alpha: 1,
                index: 0,
                isOffScreen: true,
                layer: 0,
                isOnScreen: false,
                mutationIdentity: identity)]
        }
        throw PeekabooError.windowNotFound(criteria: "windowId \(id)")
    }

    func element(for target: WindowTarget) async throws -> Element {
        switch target {
        case let .application(appIdentifier):
            let app = try await self.applicationService.findApplication(identifier: appIdentifier)
            return try self.findFirstWindow(for: app)
        case let .title(titleSubstring):
            let appsOutput = try await self.applicationService.listApplications()
            let applications = appsOutput.data.applications.filter(\.isUsableForBroadAutomationDiscovery)
            return try self.findWindowByTitle(titleSubstring, in: applications)
        case let .applicationAndTitle(appIdentifier, titleSubstring):
            let app = try await self.applicationService.findApplication(identifier: appIdentifier)

            if let windowFromID = try await self.findWindowByTitleUsingWindowID(
                titleSubstring: titleSubstring,
                appIdentifier: appIdentifier,
                app: app)
            {
                return windowFromID
            }

            return try self.findWindowByTitleInApp(titleSubstring, app: app)
        case let .index(appIdentifier, index):
            let app = try await self.applicationService.findApplication(identifier: appIdentifier)
            return try self.findWindowByIndex(for: app, index: index)
        case .frontmost:
            let frontmostApp = try await self.applicationService.getFrontmostApplication()
            return try self.findFirstWindow(for: frontmostApp)
        case let .windowId(id):
            if let handle = self.windowIdentityService.findWindow(
                byID: CGWindowID(id),
                messagingTimeout: 1.0)
            {
                return handle.element
            }
            throw PeekabooError.windowNotFound(criteria: "windowId \(id)")
        }
    }

    func findFirstWindow(for app: ServiceApplicationInfo) throws -> Element {
        guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else {
            throw NotFoundError.application(app.name)
        }
        let appElement = AXApp(runningApp).element

        guard let windows = appElement.windows(), !windows.isEmpty else {
            throw NotFoundError.window(app: app.name)
        }

        if let renderable = self.firstRenderableWindow(from: windows, appName: app.name) {
            return renderable
        }

        self.logger.debug("Falling back to first AX window for \(app.name); no renderable window detected")
        return windows[0]
    }

    func findWindowByIndex(for app: ServiceApplicationInfo, index: Int) throws -> Element {
        guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else {
            throw NotFoundError.application(app.name)
        }
        let appElement = AXApp(runningApp).element

        guard let windows = appElement.windows() else {
            throw NotFoundError.window(app: app.name)
        }

        guard index >= 0, index < windows.count else {
            throw PeekabooError.invalidInput(
                "windowIndex: Index \(index) is out of range. Available windows: 0-\(windows.count - 1)")
        }

        return windows[index]
    }

    func firstRenderableWindow(from windows: [Element], appName: String) -> Element? {
        let minimumDimension: CGFloat = 50

        for (idx, window) in windows.indexed() {
            if window.isMinimized() == true {
                self.logger.debug("Skipping minimized window idx \(idx) for \(appName)")
                continue
            }

            guard
                let size = window.size(),
                size.width >= minimumDimension,
                size.height >= minimumDimension,
                let position = window.position()
            else {
                self.logger.debug("Skipping tiny window idx \(idx) for \(appName)")
                continue
            }

            let bounds = CGRect(origin: position, size: size)
            guard bounds.width >= minimumDimension, bounds.height >= minimumDimension else {
                self.logger.debug("Skipping non-renderable window idx \(idx) for \(appName)")
                continue
            }

            self.logger.debug(
                "Selected renderable window idx \(idx) for \(appName) with bounds \(String(describing: bounds))")
            return window
        }

        return nil
    }

    func findWindowByTitleUsingWindowID(
        titleSubstring: String,
        appIdentifier: String,
        app: ServiceApplicationInfo) async throws -> Element?
    {
        guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else {
            throw NotFoundError.application(app.name)
        }

        let windows = try await self.windows(for: appIdentifier)
        guard let match = windows.first(where: { $0.title.localizedCaseInsensitiveContains(titleSubstring) }) else {
            return nil
        }

        let windowID = CGWindowID(match.windowID)
        if let handle = self.windowIdentityService.findWindow(byID: windowID, in: runningApp) {
            return handle.element
        }

        // AXWindowResolver couldn't find it, fall back to scanning the app's AX windows by CGWindowID.
        return try self.findWindowById(Int(windowID), in: [app])
    }

    func findWindowById(_ id: Int, in apps: [ServiceApplicationInfo]) throws -> Element {
        for app in apps {
            guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else { continue }
            let appElement = AXApp(runningApp).element

            guard let windows = appElement.windows() else { continue }
            for window in windows {
                if let windowID = self.windowIdentityService.getWindowID(from: window),
                   Int(windowID) == id
                {
                    self.logger.debug("Matched window id \(id) in app \(app.name)")
                    return window
                }
            }
        }

        throw PeekabooError.windowNotFound(criteria: "windowId \(id)")
    }
}

extension ServiceWindowInfo {
    func withExactAXState(title: String, bounds: CGRect, isMinimized: Bool) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: self.windowID,
            title: title.isEmpty ? self.title : title,
            bounds: bounds,
            isMinimized: isMinimized,
            isMainWindow: self.isMainWindow,
            isKeyWindow: self.isKeyWindow,
            isFrontmost: self.isFrontmost,
            subrole: self.subrole,
            windowLevel: self.windowLevel,
            alpha: self.alpha,
            index: self.index,
            spaceID: self.spaceID,
            spaceName: self.spaceName,
            screenIndex: self.screenIndex,
            screenName: self.screenName,
            isOffScreen: isMinimized || self.isOffScreen,
            layer: self.layer,
            isOnScreen: isMinimized ? false : self.isOnScreen,
            sharingState: self.sharingState,
            isExcludedFromWindowsMenu: self.isExcludedFromWindowsMenu,
            mutationIdentity: self.mutationIdentity.map { identity in
                WindowMutationIdentity(
                    windowID: identity.windowID,
                    ownerProcessIdentifier: identity.ownerProcessIdentifier,
                    ownerProcessStartIdentity: identity.ownerProcessStartIdentity,
                    capturedBounds: bounds,
                    isMinimized: isMinimized)
            })
    }
}

struct BoundedAXWindowIdentitySnapshot: Sendable, Equatable {
    let windowID: Int
    let ownerProcessIdentifier: pid_t
    let ownerProcessStartIdentity: UInt64
    let title: String
    let bounds: CGRect
    let isMinimized: Bool
}

struct BoundedAXWindowScanReceipt: Sendable, Equatable {
    let windowID: Int
    let ownerProcessIdentifier: pid_t
    let ownerProcessStartIdentity: UInt64
}

enum BoundedAXWindowIdentityScanner {
    static func find(
        windowID: Int,
        processIdentifiers: [pid_t],
        timeout: TimeInterval,
        processStartIdentityProvider: @Sendable (pid_t) -> UInt64? =
            SystemIdentityResolver.processStartIdentity) -> BoundedAXWindowIdentitySnapshot?
    {
        guard let requestedID = CGWindowID(exactly: windowID) else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        for processIdentifier in processIdentifiers where ContinuousClock.now < deadline {
            guard let processStartIdentity = processStartIdentityProvider(processIdentifier) else {
                continue
            }
            if let snapshot = self.scanProcess(
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity,
                requestedID: requestedID,
                deadline: deadline,
                processStartIdentityProvider: processStartIdentityProvider)
            {
                return snapshot
            }
        }
        return nil
    }

    private static func scanProcess(
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        requestedID: CGWindowID,
        deadline: ContinuousClock.Instant,
        processStartIdentityProvider: @Sendable (pid_t) -> UInt64?) -> BoundedAXWindowIdentitySnapshot?
    {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let callTimeout = self.remainingCallTimeout(until: deadline) else { return nil }
        let windows: [AXUIElement]? = AXChildWindowMessagingTimeout.perform(
            on: application,
            timeout: callTimeout)
        { applicationElement in
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                applicationElement,
                kAXWindowsAttribute as CFString,
                &windowsValue) == .success
            else {
                return nil
            }
            return windowsValue as? [AXUIElement]
        }
        guard let windows else { return nil }

        guard let snapshot = self.scanWindows(
            windows,
            remainingTimeout: { self.remainingCallTimeout(until: deadline) },
            applyTimeout: { AXUIElementSetMessagingTimeout($0, $1) },
            snapshot: { childWindow in
                self.snapshot(
                    from: childWindow,
                    requestedID: requestedID,
                    ownerProcessIdentifier: processIdentifier,
                    ownerProcessStartIdentity: processStartIdentity)
            })
        else { return nil }
        return self.validatedSnapshot(
            snapshot,
            expectedReceipt: BoundedAXWindowScanReceipt(
                windowID: Int(requestedID),
                ownerProcessIdentifier: processIdentifier,
                ownerProcessStartIdentity: processStartIdentity),
            liveProcessStartIdentity: processStartIdentityProvider(processIdentifier))
    }

    static func scanWindows<Window>(
        _ windows: [Window],
        remainingTimeout: () -> Float?,
        applyTimeout: (Window, Float) -> Void,
        snapshot: (Window) -> BoundedAXWindowIdentitySnapshot?) -> BoundedAXWindowIdentitySnapshot?
    {
        for window in windows {
            guard let timeout = remainingTimeout() else { return nil }
            if let result = AXChildWindowMessagingTimeout.perform(
                timeout: timeout,
                applyTimeout: { applyTimeout(window, $0) },
                operation: { snapshot(window) })
            {
                return result
            }
        }
        return nil
    }

    private static func snapshot(
        from window: AXUIElement,
        requestedID: CGWindowID,
        ownerProcessIdentifier: pid_t,
        ownerProcessStartIdentity: UInt64) -> BoundedAXWindowIdentitySnapshot?
    {
        var candidateID: CGWindowID = 0
        guard AXWindowIDResolver.copyWindowID(window, into: &candidateID) == .success,
              candidateID == requestedID
        else {
            return nil
        }
        let position = self.pointAttribute(kAXPositionAttribute, of: window) ?? .zero
        let size = self.sizeAttribute(kAXSizeAttribute, of: window) ?? .zero
        return BoundedAXWindowIdentitySnapshot(
            windowID: Int(requestedID),
            ownerProcessIdentifier: ownerProcessIdentifier,
            ownerProcessStartIdentity: ownerProcessStartIdentity,
            title: self.stringAttribute(kAXTitleAttribute, of: window) ?? "",
            bounds: CGRect(origin: position, size: size),
            isMinimized: self.boolAttribute(kAXMinimizedAttribute, of: window) == true)
    }

    private static func remainingCallTimeout(until deadline: ContinuousClock.Instant) -> Float? {
        let remaining = Self.seconds(ContinuousClock.now.duration(to: deadline))
        return self.callTimeout(remainingSeconds: remaining)
    }

    static func callTimeout(remainingSeconds: TimeInterval) -> Float? {
        guard remainingSeconds > 0 else { return nil }
        let timeout = Float(min(0.1, remainingSeconds))
        return timeout > 0 ? timeout : nil
    }

    static func validatedSnapshot(
        _ snapshot: BoundedAXWindowIdentitySnapshot,
        expectedReceipt: BoundedAXWindowScanReceipt,
        liveProcessStartIdentity: UInt64?) -> BoundedAXWindowIdentitySnapshot?
    {
        guard snapshot.windowID == expectedReceipt.windowID,
              snapshot.ownerProcessIdentifier == expectedReceipt.ownerProcessIdentifier,
              snapshot.ownerProcessStartIdentity == expectedReceipt.ownerProcessStartIdentity,
              liveProcessStartIdentity == expectedReceipt.ownerProcessStartIdentity
        else {
            return nil
        }
        return snapshot
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func pointAttribute(_ name: String, of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard
            AXValueGetType(axValue) == .cgPoint
        else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ name: String, of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard
            AXValueGetType(axValue) == .cgSize
        else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
