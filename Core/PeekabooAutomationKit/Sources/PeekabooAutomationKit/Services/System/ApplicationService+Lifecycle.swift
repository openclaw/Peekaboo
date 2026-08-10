import AppKit
import ApplicationServices
import AXorcist
import Foundation
import os.log
import PeekabooFoundation

@MainActor
extension ApplicationService {
    struct PreparedApplicationLaunch {
        let applicationURL: URL?
        let openURLs: [URL]
        let activates: Bool
        let waitUntilReady: Bool
        let waitForWindow: Bool
        let createsNewInstance: Bool
        let disablesRunningApplicationSubstitution: Bool
    }

    public func launchApplication(identifier: String) async throws -> ServiceApplicationInfo {
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.logger.info("Launching application: \(trimmedIdentifier)")

        do {
            let existingApplication = try await self.findApplication(identifier: trimmedIdentifier)
            self.logger.debug("Application already running: \(existingApplication.name)")
            return existingApplication
        } catch {
            self.logger.debug("Application not currently running: \(trimmedIdentifier), will try to launch")
        }

        return try await self.launchApplication(request: ApplicationLaunchRequest(applicationIdentifier: identifier))
    }

    public func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        let identifier = request.applicationIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleIdentifier = request.applicationBundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.logger.info("Launching application: \(bundleIdentifier ?? identifier ?? "default handler")")

        let preparedLaunch = try self.prepareApplicationLaunch(request)
        return try await self.performApplicationLaunch(preparedLaunch)
    }

    func prepareApplicationLaunch(_ request: ApplicationLaunchRequest) throws -> PreparedApplicationLaunch {
        let identifier = request.applicationIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleIdentifier = request.applicationBundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if request.applicationIdentifier != nil, identifier?.isEmpty != false {
            throw PeekabooError.invalidInput("Application identifier must not be empty")
        }
        if request.applicationBundleIdentifier != nil, bundleIdentifier?.isEmpty != false {
            throw PeekabooError.invalidInput("Application bundle identifier must not be empty")
        }
        guard !(identifier?.isEmpty == false && bundleIdentifier?.isEmpty == false) else {
            throw PeekabooError.invalidInput(
                "Application launch accepts either an application identifier or bundle identifier, not both")
        }
        guard identifier?.isEmpty == false || bundleIdentifier?.isEmpty == false || !request.openURLs.isEmpty else {
            throw PeekabooError.invalidInput("Application launch requires an identifier or URL")
        }

        let applicationURL: URL? = if let bundleIdentifier, !bundleIdentifier.isEmpty {
            try self.resolveApplicationURL(bundleIdentifier: bundleIdentifier)
        } else {
            try identifier.flatMap { identifier in
                identifier.isEmpty ? nil : try self.resolveApplicationURL(identifier)
            }
        }
        if applicationURL == nil, request.openURLs.count != 1 {
            throw PeekabooError.invalidInput("Opening multiple URLs requires an application identifier")
        }

        return PreparedApplicationLaunch(
            applicationURL: applicationURL,
            openURLs: request.openURLs,
            activates: request.activates,
            waitUntilReady: request.waitUntilReady,
            waitForWindow: request.waitForWindow,
            createsNewInstance: request.createsNewInstance,
            disablesRunningApplicationSubstitution: identifier.map(Self.isExplicitApplicationPath) == true)
    }

    private func performApplicationLaunch(_ launch: PreparedApplicationLaunch) async throws -> ServiceApplicationInfo {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            try await self.performApplicationLaunchWithOwnedLane(launch)
        }
    }

    private func performApplicationLaunchWithOwnedLane(
        _ launch: PreparedApplicationLaunch) async throws -> ServiceApplicationInfo
    {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = launch.activates
        config.createsNewApplicationInstance = launch.createsNewInstance
        if launch.createsNewInstance {
            config.allowsRunningApplicationSubstitution = false
        }

        // Opening a URL can trigger a second, delayed activation after the handler returns (Safari
        // is a common example when a page presents a dialog). Keep the same bounded native guard
        // used for launches, but cover that longer delivery window when documents/URLs are involved.
        let backgroundActivationGraceDuration: Duration = launch.openURLs.isEmpty
            ? self.backgroundLaunchActivationGraceDuration
            : self.backgroundOpenActivationGraceDuration
        let activationLease = launch.activates
            ? nil
            : self.backgroundActivationLeaseFactory(
                backgroundActivationGraceDuration,
                BackgroundRestorationDependencies(
                    applicationActivationHandler: self.applicationActivationHandler,
                    accessibilityActivationHandler: self.applicationAccessibilityActivationHandler,
                    applicationActiveProvider: self.applicationActiveProvider,
                    applicationTerminatedProvider: { $0.isTerminated },
                    frontmostProcessIdentifierProvider: self.frontmostProcessIdentifierProvider,
                    processStartIdentityProvider: self.processStartIdentityProvider,
                    confirmationSleepHandler: { duration in
                        try? await self.applicationActivationSleepHandler(duration)
                    },
                    confirmationTimeout: self.applicationActivationTimeout))

        do {
            // LaunchServices may continue opening an application after its caller is cancelled. Keep
            // ownership of that native operation until it returns a PID so the activation guard and
            // global desktop lane cannot be abandoned while the app may still activate later.
            let openTask = Task { @MainActor in
                if let applicationURL = launch.applicationURL {
                    if launch.disablesRunningApplicationSubstitution {
                        config.allowsRunningApplicationSubstitution = false
                    }
                    self.logger.debug("Launching app from URL: \(applicationURL.path)")

                    return try await self.applicationOpenHandler(applicationURL, launch.openURLs, config)
                }
                let targetURL = launch.openURLs[0]
                return try await self.defaultApplicationOpenHandler(targetURL, config)
            }
            let runningApp = try await openTask.value
            let launchProcessIdentity = try self.captureLaunchProcessIdentity(runningApp)
            activationLease?.setTargetProcessIdentity(launchProcessIdentity)
            try Task.checkCancellation()

            if launch.activates, !runningApp.isActive, !runningApp.activate(options: []) {
                self.logger
                    .warning("Launch succeeded but failed to activate \(runningApp.localizedName ?? "application")")
            }

            try await self.waitUntilReadyIfNeeded(runningApp, requested: launch.waitUntilReady)
            try await self.waitForWindowIfNeeded(runningApp, requested: launch.waitForWindow)
            try await self.waitUntilActiveIfNeeded(runningApp, requested: launch.activates)
            try await activationLease?.holdThroughInitialActivationWindow()

            let launchMessage =
                "Successfully launched: \(runningApp.localizedName ?? "Unknown") (PID: \(runningApp.processIdentifier))"
            self.logger.info("\(launchMessage)")
            let application = self.createApplicationInfo(from: runningApp)
            guard application.processIdentity == launchProcessIdentity else {
                throw PeekabooError.commandFailed(
                    "Launched application process generation changed before its receipt could be returned")
            }
            return application
        } catch {
            _ = await activationLease?.waitForReconciliation()
            throw error
        }
    }

    /// Capture the process generation while the exact `NSRunningApplication` selected by
    /// LaunchServices is still live. The result is retained through readiness and compared with
    /// the final application snapshot, so a recycled numeric PID can never become a launch receipt.
    private func captureLaunchProcessIdentity(
        _ application: NSRunningApplication) throws -> ApplicationProcessIdentity
    {
        let processIdentifier = application.processIdentifier
        guard processIdentifier > 0,
              !application.isTerminated,
              let processStartIdentity = self.processStartIdentityProvider(processIdentifier),
              !application.isTerminated,
              self.processStartIdentityProvider(processIdentifier) == processStartIdentity
        else {
            throw PeekabooError.commandFailed(
                "Could not capture a stable process-generation identity for the launched application")
        }
        return ApplicationProcessIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity)
    }

    public func relaunchApplication(request: ApplicationRelaunchRequest) async throws -> ServiceApplicationInfo {
        guard request.waitSeconds.isFinite, request.waitSeconds >= 0 else {
            throw PeekabooError.invalidInput("Relaunch wait must be a finite, non-negative number of seconds")
        }

        // Resolve every launch prerequisite before mutating the target application.
        let preparedLaunch = try self.prepareApplicationLaunch(request.launchRequest)
        guard let expectedTargetIdentity = request.expectedTargetIdentity else {
            throw PeekabooError.commandFailed(
                "Atomic relaunch requires the initially selected process-generation receipt")
        }
        let target = try await self.resolveRelaunchTarget(request.targetIdentifier)
        guard target.processIdentity == expectedTargetIdentity else {
            throw PeekabooError.commandFailed(
                "The relaunch target changed process generation after initial selection")
        }
        if target.processIdentifier == getpid() {
            throw PeekabooError.serviceUnavailable("A runtime host cannot relaunch itself")
        }
        let canonicalTargetIdentifier = "PID:\(target.processIdentifier)"
        let quitRequest = ApplicationQuitRequest(
            identifier: canonicalTargetIdentifier,
            force: request.force,
            expectedIdentity: expectedTargetIdentity)

        return try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            try self.validateApplicationQuitIdentity(
                expectedTargetIdentity,
                resolvedApplication: target)
            guard try await self.quitRelaunchTarget(
                quitRequest,
                resolvedApplication: target,
                expectedIdentity: expectedTargetIdentity)
            else {
                throw PeekabooError.commandFailed("Application refused to quit")
            }

            let terminationDeadline = Date().addingTimeInterval(5)
            while try await self.isRelaunchTargetRunning(identifier: canonicalTargetIdentifier) {
                guard Date() < terminationDeadline else {
                    throw PeekabooError.timeout("Application did not terminate within 5 seconds")
                }
                try await Task.sleep(for: .milliseconds(100))
            }

            if request.waitSeconds > 0 {
                try await Task.sleep(for: .seconds(request.waitSeconds))
            }
            return try await self.performApplicationLaunchWithOwnedLane(preparedLaunch)
        }
    }

    private func resolveRelaunchTarget(_ identifier: String) async throws -> ServiceApplicationInfo {
        if let relaunchTargetResolver = self.relaunchTargetResolver {
            return try await relaunchTargetResolver(identifier)
        }
        return try await self.findApplication(identifier: identifier)
    }

    private func quitRelaunchTarget(
        _ request: ApplicationQuitRequest,
        resolvedApplication: ServiceApplicationInfo,
        expectedIdentity: ApplicationProcessIdentity) async throws -> Bool
    {
        if let relaunchQuitHandler = self.relaunchQuitHandler {
            return try await relaunchQuitHandler(request)
        }
        return try await self.quitApplicationWithOwnedLane(
            request: request,
            resolvedApplication: resolvedApplication,
            expectedIdentity: expectedIdentity)
    }

    private func isRelaunchTargetRunning(identifier: String) async throws -> Bool {
        if let relaunchRunningHandler = self.relaunchRunningHandler {
            return try await relaunchRunningHandler(identifier)
        }
        return await self.isApplicationRunning(identifier: identifier)
    }

    func resolveApplicationURL(_ identifier: String) throws -> URL {
        let expanded = NSString(string: identifier).expandingTildeInPath
        if identifier.contains("/"), FileManager.default.fileExists(atPath: expanded) {
            return URL(fileURLWithPath: expanded)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            self.logger.debug("Found app by bundle ID at: \(url.path)")
            return url
        }
        if let url = self.findApplicationByName(identifier) {
            self.logger.debug("Found app by name at: \(url.path)")
            return url
        }
        self.logger.error("Application not found in system: \(identifier)")
        throw PeekabooError.appNotFound(identifier)
    }

    func resolveApplicationURL(bundleIdentifier: String) throws -> URL {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            self.logger.error("Application bundle identifier not found: \(bundleIdentifier)")
            throw PeekabooError.appNotFound(bundleIdentifier)
        }
        self.logger.debug("Found app by bundle ID at: \(url.path)")
        return url
    }

    private static func isExplicitApplicationPath(_ identifier: String) -> Bool {
        let expanded = NSString(string: identifier).expandingTildeInPath
        return identifier.contains("/") && FileManager.default.fileExists(atPath: expanded)
    }

    private func waitUntilReadyIfNeeded(_ app: NSRunningApplication, requested: Bool) async throws {
        guard requested else { return }
        let deadline = Date().addingTimeInterval(self.applicationReadinessTimeout)
        while !app.isFinishedLaunching {
            try Task.checkCancellation()
            guard !app.isTerminated else {
                throw PeekabooError.commandFailed("Application terminated before it finished launching")
            }
            guard Date() < deadline else {
                throw PeekabooError.timeout(
                    "Application did not become ready within \(self.applicationReadinessTimeout) seconds")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func waitForWindowIfNeeded(_ app: NSRunningApplication, requested: Bool) async throws {
        guard requested else { return }
        let deadline = Date().addingTimeInterval(self.applicationReadinessTimeout)
        while !self.applicationReadinessHandler(app) {
            try Task.checkCancellation()
            guard !app.isTerminated else {
                throw PeekabooError.commandFailed("Application terminated before it exposed a window")
            }
            guard Date() < deadline else {
                throw PeekabooError.timeout(
                    "Application did not expose an automatable window within " +
                        "\(self.applicationReadinessTimeout) seconds")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    static func isReadyForAutomation(_ app: NSRunningApplication) -> Bool {
        guard app.isFinishedLaunching, !app.isTerminated else { return false }

        // `--wait-for-window` promises a window that subsequent exact capture/automation can
        // address. AX can expose a window before WindowServer has assigned its public ID; returning
        // in that interval produced `window_ready: true`, `window_count: 0`. Wait for the exact
        // WindowServer identity instead of reporting an unusable intermediate AX-only state.
        return self.hasWindowServerWindow(processIdentifier: app.processIdentifier)
    }

    private static func hasWindowServerWindow(processIdentifier: pid_t) -> Bool {
        guard let windows = WindowInfoHelper.getWindows(for: processIdentifier) else {
            return false
        }

        return windows.contains { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else {
                return false
            }
            return bounds.width > 1 && bounds.height > 1
        }
    }

    private func waitUntilActiveIfNeeded(_ app: NSRunningApplication, requested: Bool) async throws {
        guard requested else { return }
        let deadline = Date().addingTimeInterval(2)
        while !app.isActive, Date() < deadline {
            _ = app.activate(options: [])
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard app.isActive else {
            throw PeekabooError.timeout(
                "Application did not become active within 2 seconds: \(app.localizedName ?? "unknown")")
        }
    }

    public func activateApplication(identifier: String) async throws {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            self.logger.info("Activating application: \(identifier)")
            let app = try await findApplication(identifier: identifier)

            // Create NSRunningApplication
            let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier)
            guard let runningApp else {
                throw PeekabooError.operationError(
                    message: "Failed to activate application: Could not find running application process")
            }

            try await self.requestVerifiedActivation(runningApp, applicationName: app.name)
            self.logger.info("Successfully activated and verified frontmost: \(app.name)")
        }
    }

    private func requestVerifiedActivation(
        _ application: NSRunningApplication,
        applicationName: String) async throws
    {
        let processIdentifier = application.processIdentifier
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: self.applicationActivationTimeout)
        var shouldUseAccessibilityFallback = false
        var nativeRequestAccepted = false
        var accessibilityRequestAccepted = false

        repeat {
            try Task.checkCancellation()
            guard !application.isTerminated else {
                throw PeekabooError.operationError(
                    message: "Failed to activate \(applicationName): application terminated during activation")
            }
            if self.isVerifiedActive(application, processIdentifier: processIdentifier) {
                return
            }

            let accepted = self.applicationActivationHandler(application)
            nativeRequestAccepted = nativeRequestAccepted || accepted
            if shouldUseAccessibilityFallback || !accepted {
                accessibilityRequestAccepted = self.applicationAccessibilityActivationHandler(processIdentifier) ||
                    accessibilityRequestAccepted
            }

            if self.isVerifiedActive(application, processIdentifier: processIdentifier) {
                return
            }

            let now = clock.now
            guard now < deadline else { break }
            try await self.applicationActivationSleepHandler(min(.milliseconds(100), now.duration(to: deadline)))
            shouldUseAccessibilityFallback = true
        } while true

        let frontmostDescription = NSWorkspace.shared.frontmostApplication.map {
            "\($0.localizedName ?? "unknown") (PID: \($0.processIdentifier))"
        } ?? "none"
        let windowServerState = self.windowServerActivationStateProvider(processIdentifier)
        let frontmostWindowDescription = windowServerState.frontmostWindowProcessIdentifier
            .map(String.init) ?? "none"
        let diagnostic = "Activation verification failed for \(applicationName) " +
            "(native accepted: \(nativeRequestAccepted), AX accepted: \(accessibilityRequestAccepted), " +
            "frontmost: \(frontmostDescription), frontmost window PID: \(frontmostWindowDescription))"
        self.logger.error("\(diagnostic, privacy: .public)")
        throw PeekabooError.timeout(
            "Application did not become active and frontmost: \(applicationName). " +
                "Frontmost application: \(frontmostDescription). " +
                "Frontmost window PID: \(frontmostWindowDescription)")
    }

    private func isVerifiedActive(
        _ application: NSRunningApplication,
        processIdentifier: pid_t) -> Bool
    {
        let windowServerState = self.windowServerActivationStateProvider(processIdentifier)
        return Self.isVerifiedApplicationActivation(
            processIdentifier: processIdentifier,
            isActive: self.applicationActiveProvider(application),
            frontmostProcessIdentifier: self.frontmostProcessIdentifierProvider(),
            targetHasVisibleWindow: windowServerState.targetHasVisibleWindow,
            frontmostWindowProcessIdentifier: windowServerState.frontmostWindowProcessIdentifier)
    }

    static func isVerifiedApplicationActivation(
        processIdentifier: pid_t,
        isActive: Bool,
        frontmostProcessIdentifier: pid_t?,
        targetHasVisibleWindow: Bool,
        frontmostWindowProcessIdentifier: pid_t?) -> Bool
    {
        guard isActive, frontmostProcessIdentifier == processIdentifier else {
            return false
        }
        return !targetHasVisibleWindow || frontmostWindowProcessIdentifier == processIdentifier
    }

    static func windowServerActivationState(processIdentifier: pid_t) -> WindowServerActivationState {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        var frontmostWindowProcessIdentifier: pid_t?
        var targetHasVisibleWindow = false

        for window in windows {
            guard let ownerProcessIdentifier =
                (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
            else {
                continue
            }
            if frontmostWindowProcessIdentifier == nil {
                frontmostWindowProcessIdentifier = ownerProcessIdentifier
            }
            if ownerProcessIdentifier == processIdentifier {
                targetHasVisibleWindow = true
            }
        }

        return WindowServerActivationState(
            targetHasVisibleWindow: targetHasVisibleWindow,
            frontmostWindowProcessIdentifier: frontmostWindowProcessIdentifier)
    }

    static func requestAccessibilityActivation(processIdentifier: pid_t) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        return AXUIElementSetAttributeValue(
            applicationElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue) == .success
    }

    public func quitApplication(identifier: String, force: Bool = false) async throws -> Bool {
        let selectedApplication = try await self.findApplication(identifier: identifier)
        guard let expectedIdentity = selectedApplication.processIdentity else {
            throw PeekabooError.commandFailed(
                "Could not capture a stable process-generation identity for \(selectedApplication.name)")
        }
        return try await self.quitApplication(request: ApplicationQuitRequest(
            identifier: "PID:\(selectedApplication.processIdentifier)",
            force: force,
            expectedIdentity: expectedIdentity))
    }

    public func quitApplication(request: ApplicationQuitRequest) async throws -> Bool {
        self.logger.info("Quitting application: \(request.identifier) (force: \(request.force))")
        let app = try await findApplication(identifier: request.identifier)
        let expectedIdentity: ApplicationProcessIdentity
        if let requestedIdentity = request.expectedIdentity {
            expectedIdentity = requestedIdentity
        } else if let resolvedIdentity = app.processIdentity {
            expectedIdentity = resolvedIdentity
        } else {
            throw PeekabooError.commandFailed(
                "Could not capture a stable process-generation identity for \(app.name)")
        }
        try self.validateApplicationQuitIdentity(expectedIdentity, resolvedApplication: app)

        return try await self.operationLaneCoordinator.run(scope: .process(expectedIdentity), access: .write) {
            try await self.quitApplicationWithOwnedLane(
                request: request,
                resolvedApplication: app,
                expectedIdentity: expectedIdentity)
        }
    }

    private func quitApplicationWithOwnedLane(
        request: ApplicationQuitRequest,
        resolvedApplication app: ServiceApplicationInfo,
        expectedIdentity: ApplicationProcessIdentity) async throws -> Bool
    {
        try self.validateApplicationQuitIdentity(expectedIdentity, resolvedApplication: app)

        // Create NSRunningApplication
        let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier)
        guard let runningApp else {
            throw PeekabooError.appNotFound(request.identifier)
        }

        self.logger.debug("Sending \(request.force ? "force terminate" : "terminate") signal to \(app.name)")
        try self.validateApplicationQuitIdentity(expectedIdentity, resolvedApplication: app)
        let success = self.applicationQuitHandler(runningApp, request.force)

        guard success else {
            self.logger.error("Failed to quit: \(app.name)")
            return false
        }

        let terminated = try await waitForApplicationTermination(timeoutSeconds: 3) {
            runningApp.isTerminated || NSRunningApplication(processIdentifier: app.processIdentifier) == nil
        }
        if terminated {
            self.logger.info("Successfully quit and verified termination: \(app.name)")
        } else {
            let message = "Quit request was accepted but the process remained alive: \(app.name) " +
                "(PID: \(app.processIdentifier))"
            self.logger.error("\(message, privacy: .public)")
        }
        return terminated
    }

    private func validateApplicationQuitIdentity(
        _ expectedIdentity: ApplicationProcessIdentity,
        resolvedApplication: ServiceApplicationInfo) throws
    {
        guard expectedIdentity.processIdentifier == resolvedApplication.processIdentifier,
              resolvedApplication.processStartIdentity == expectedIdentity.processStartIdentity,
              self.processStartIdentityProvider(resolvedApplication.processIdentifier) ==
              expectedIdentity.processStartIdentity
        else {
            throw PeekabooError.commandFailed(
                "Application PID \(expectedIdentity.processIdentifier) disappeared or changed process generation")
        }
    }

    public func hideApplication(identifier: String) async throws {
        self.logger.info("Hiding application: \(identifier)")
        let app = try await findApplication(identifier: identifier)
        guard let processIdentity = app.processIdentity else {
            throw PeekabooError.commandFailed("Could not capture a stable process-generation identity for \(app.name)")
        }
        try await self.operationLaneCoordinator.run(scope: .process(processIdentity), access: .write) {
            try self.validateApplicationQuitIdentity(processIdentity, resolvedApplication: app)

            guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else {
                throw NotFoundError.application(identifier)
            }
            let appElement = AXApp(runningApp).element

            do {
                try appElement.performAction(Attribute<String>("AXHide"))
                self.logger.debug("Hidden via AX action: \(app.name)")
            } catch {
                // Log the error but use fallback
                _ = error.asPeekabooError(context: "AX hide action failed for \(app.name)")
                // Fallback to NSRunningApplication method
                self.logger.debug("Using NSRunningApplication fallback")
                let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier)
                if let runningApp {
                    runningApp.hide()
                    self.logger.debug("Hidden via NSRunningApplication: \(app.name)")
                }
            }
        }
    }

    public func unhideApplication(identifier: String) async throws {
        self.logger.info("Unhiding application: \(identifier)")
        let app = try await findApplication(identifier: identifier)
        guard let processIdentity = app.processIdentity else {
            throw PeekabooError.commandFailed("Could not capture a stable process-generation identity for \(app.name)")
        }
        try await self.operationLaneCoordinator.run(scope: .process(processIdentity), access: .write) {
            try self.validateApplicationQuitIdentity(processIdentity, resolvedApplication: app)

            guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else {
                throw NotFoundError.application(identifier)
            }
            let requestSent = runningApp.unhide()
            let deadline = Date().addingTimeInterval(1)
            repeat {
                // NSRunningApplication state is cached until the next main run-loop turn.
                try await Task.sleep(for: .milliseconds(50))
                guard runningApp.isHidden else {
                    self.logger.debug("Unhidden application without activation: \(app.name)")
                    return
                }
            } while Date() < deadline

            if requestSent {
                throw PeekabooError.operationError(message: "Application remained hidden: \(app.name)")
            }
            throw PeekabooError.operationError(message: "Failed to request unhide for application: \(app.name)")
        }
    }

    public func hideOtherApplications(identifier: String) async throws {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            self.logger.info("Hiding other applications except: \(identifier)")
            let app = try await findApplication(identifier: identifier)

            guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else {
                throw NotFoundError.application(identifier)
            }
            let appElement = AXApp(runningApp).element

            do {
                // Use custom attribute for hide others action
                try appElement.performAction(Attribute<String>("AXHideOthers"))
                self.logger.debug("Hidden others via AX action")
            } catch {
                // Log the error but use fallback
                _ = error.asPeekabooError(context: "AX hide others action failed")
                // Fallback: hide each app individually
                self.logger.debug("Hiding apps individually")
                // Already on main thread due to @MainActor on class
                let apps = NSWorkspace.shared.runningApplications
                var hiddenCount = 0
                for runningApp in apps {
                    if runningApp.processIdentifier != app.processIdentifier,
                       runningApp.activationPolicy == .regular,
                       runningApp.bundleIdentifier != "com.apple.finder"
                    {
                        runningApp.hide()
                        hiddenCount += 1
                    }
                }
                // Return value already computed
                self.logger.debug("Hidden \(hiddenCount) other applications")
            }
        }
    }

    public func showAllApplications() async throws {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            self.logger.info("Showing all applications")
            let systemWide = Element.systemWide()

            do {
                // Use custom attribute for show all action
                try systemWide.performAction(Attribute<String>("AXShowAll"))
                self.logger.debug("Shown all via AX action")
            } catch {
                // Log the error but use fallback
                _ = error.asPeekabooError(context: "AX show all action failed")
                // Fallback: unhide each hidden app
                self.logger.debug("Unhiding apps individually")
                // Already on main thread due to @MainActor on class
                let apps = NSWorkspace.shared.runningApplications
                var unhiddenCount = 0
                for runningApp in apps {
                    if runningApp.isHidden, runningApp.activationPolicy == .regular {
                        runningApp.unhide()
                        unhiddenCount += 1
                    }
                }
                // Return value already computed
                self.logger.debug("Unhidden \(unhiddenCount) applications")
            }
        }
    }

    private func findApplicationByName(_ name: String) -> URL? {
        self.logger.debug("Searching for application by name: \(name)")

        // First, try exact name in common directories
        let searchPaths = [
            "/Applications",
            "/System/Applications",
            "/System/Library/CoreServices",
            "/Applications/Utilities",
            "~/Applications",
        ].map { NSString(string: $0).expandingTildeInPath }

        let fileManager = FileManager.default

        for path in searchPaths {
            let searchName = name.hasSuffix(".app") ? name : "\(name).app"
            let fullPath = (path as NSString).appendingPathComponent(searchName)

            if fileManager.fileExists(atPath: fullPath) {
                self.logger.debug("Found app at: \(fullPath)")
                return URL(fileURLWithPath: fullPath)
            }
        }

        // Try NSWorkspace API with bundle ID
        // Already on main thread due to @MainActor on class
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            self.logger.debug("Found app via bundle identifier: \(url.path)")
            return url
        }

        // Use Spotlight search for more flexible app discovery
        if let url = searchApplicationWithSpotlight(name) {
            self.logger.debug("Found app via Spotlight: \(url.path)")
            return url
        }

        self.logger.debug("Application not found by name: \(name)")
        return nil
    }

    @MainActor
    private func searchApplicationWithSpotlight(_ name: String) -> URL? {
        SpotlightApplicationSearcher(logger: self.logger, name: name).search()
    }
}

@MainActor
func waitForApplicationTermination(
    timeoutSeconds: TimeInterval,
    pollInterval: Duration = .milliseconds(100),
    isTerminated: () async -> Bool) async throws -> Bool
{
    try Task.checkCancellation()
    if await isTerminated() {
        return true
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(max(0, timeoutSeconds)))
    while clock.now < deadline {
        try await Task.sleep(for: pollInterval)
        try Task.checkCancellation()
        if await isTerminated() {
            return true
        }
    }

    try Task.checkCancellation()
    return await isTerminated()
}

enum BackgroundRestorationOutcome: Sendable, Equatable {
    case candidateConfirmed(pid_t)
    case differentFrontmost(pid_t)
    case targetWasAlreadyFrontmost
    case targetNotFrontmost
    case targetStillFrontmost
}

@MainActor
struct BackgroundRestorationDependencies {
    typealias ApplicationActivationHandler = @MainActor (NSRunningApplication) -> Bool
    typealias AccessibilityActivationHandler = @MainActor (pid_t) -> Bool
    typealias ApplicationActiveProvider = @MainActor (NSRunningApplication) -> Bool
    typealias ApplicationTerminatedProvider = @MainActor (NSRunningApplication) -> Bool
    typealias FrontmostProcessIdentifierProvider = @MainActor () -> pid_t?
    typealias ProcessStartIdentityProvider = @MainActor (pid_t) -> UInt64?
    typealias SleepHandler = @MainActor (Duration) async -> Void

    let applicationActivationHandler: ApplicationActivationHandler
    let accessibilityActivationHandler: AccessibilityActivationHandler
    let applicationActiveProvider: ApplicationActiveProvider
    let applicationTerminatedProvider: ApplicationTerminatedProvider
    let frontmostProcessIdentifierProvider: FrontmostProcessIdentifierProvider
    let processStartIdentityProvider: ProcessStartIdentityProvider
    let confirmationSleepHandler: SleepHandler
    let confirmationTimeout: Duration

    static func live(workspace: NSWorkspace = .shared) -> Self {
        Self(
            applicationActivationHandler: { $0.activate(options: [.activateAllWindows]) },
            accessibilityActivationHandler: ApplicationService.requestAccessibilityActivation,
            applicationActiveProvider: { $0.isActive },
            applicationTerminatedProvider: { $0.isTerminated },
            frontmostProcessIdentifierProvider: { workspace.frontmostApplication?.processIdentifier },
            processStartIdentityProvider: SystemIdentityResolver.processStartIdentity,
            confirmationSleepHandler: { try? await Task.sleep(for: $0) },
            confirmationTimeout: .seconds(2))
    }
}

@MainActor
final class BackgroundLaunchActivationLease {
    typealias NowProvider = @MainActor () -> ContinuousClock.Instant
    typealias SleepHandler = @MainActor (_ duration: Duration) async -> Void

    private struct ActivationRecord {
        let processIdentifier: pid_t
        let application: NSRunningApplication?
    }

    private let notificationCenter: NotificationCenter
    private let restorationDependencies: BackgroundRestorationDependencies
    private let activationGraceDuration: Duration
    private let confirmationTimeout: Duration
    private let nowProvider: NowProvider
    private let sleepHandler: SleepHandler
    private let initialFrontmostProcessIdentity: ApplicationProcessIdentity?
    private var observer: (any NSObjectProtocol)?
    private var targetProcessIdentity: ApplicationProcessIdentity?
    private var activationsBeforeTargetResolution: [ActivationRecord] = []
    private var observedNonTargetActivation = false
    private var restorationCandidate: NSRunningApplication?
    private var candidateRevision: UInt64 = 0
    private var reconciliationTask: Task<BackgroundRestorationOutcome, Never>?
    private var reconciliationOutcome: BackgroundRestorationOutcome?

    init(
        workspace: NSWorkspace = .shared,
        previousApplication: NSRunningApplication? = nil,
        observeActivations: Bool = true,
        activationGraceDuration: Duration = .milliseconds(500),
        nowProvider: @escaping NowProvider = { ContinuousClock.now },
        sleepHandler: @escaping SleepHandler = { duration in try? await Task.sleep(for: duration) },
        restorationDependencies: BackgroundRestorationDependencies? = nil)
    {
        let dependencies = restorationDependencies ?? .live(workspace: workspace)
        self.notificationCenter = workspace.notificationCenter
        self.restorationCandidate = previousApplication ?? workspace.frontmostApplication
        self.restorationDependencies = dependencies
        self.activationGraceDuration = Self.boundedProtectionDuration(activationGraceDuration)
        self.confirmationTimeout = Self.boundedProtectionDuration(dependencies.confirmationTimeout)
        self.nowProvider = nowProvider
        self.sleepHandler = sleepHandler
        self.initialFrontmostProcessIdentity = dependencies.frontmostProcessIdentifierProvider().flatMap {
            guard let processStartIdentity = dependencies.processStartIdentityProvider($0) else { return nil }
            return ApplicationProcessIdentity(
                processIdentifier: $0,
                processStartIdentity: processStartIdentity)
        }

        if observeActivations {
            self.observer = self.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main)
            { [weak self] notification in
                let application = notification
                    .userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let processIdentifier = application?.processIdentifier else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let application = NSRunningApplication(processIdentifier: processIdentifier) {
                        self.handleActivatedApplication(application)
                    } else {
                        self.handleActivatedProcessIdentifier(processIdentifier)
                    }
                }
            }
        }
    }

    @discardableResult
    func setTargetProcessIdentifier(_ processIdentifier: pid_t) -> Bool {
        guard let processStartIdentity = self.restorationDependencies
            .processStartIdentityProvider(processIdentifier)
        else { return false }
        return self.setTargetProcessIdentity(ApplicationProcessIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity))
    }

    @discardableResult
    func setTargetProcessIdentity(_ processIdentity: ApplicationProcessIdentity) -> Bool {
        guard self.targetProcessIdentity == nil else { return false }
        self.targetProcessIdentity = processIdentity
        let protectionDeadline = self.nowProvider().advanced(by: self.activationGraceDuration)
        if let latestNonTargetActivation = self.activationsBeforeTargetResolution.last(where: {
            $0.processIdentifier != processIdentity.processIdentifier
        }) {
            self.observedNonTargetActivation = true
            if let application = latestNonTargetActivation.application,
               !self.restorationDependencies.applicationTerminatedProvider(application)
            {
                self.setRestorationCandidate(application)
            } else {
                self.clearRestorationCandidate()
            }
        } else if self.restorationCandidate?.processIdentifier == processIdentity.processIdentifier {
            self.clearRestorationCandidate()
        }
        self.activationsBeforeTargetResolution.removeAll()
        self.restoreIfTargetIsFrontmost()
        self.startReconciliationTask(deadline: protectionDeadline)
        return true
    }

    func holdThroughInitialActivationWindow() async throws {
        guard let reconciliationTask else { return }
        let outcome = await reconciliationTask.value
        try Task.checkCancellation()
        if outcome == .targetStillFrontmost {
            throw PeekabooError.commandFailed(
                "Background launch could not restore focus before its protection deadline")
        }
    }

    func handleActivatedProcessIdentifier(_ processIdentifier: pid_t) {
        guard let targetProcessIdentity else {
            self.activationsBeforeTargetResolution.append(ActivationRecord(
                processIdentifier: processIdentifier,
                application: nil))
            return
        }
        guard self.reconciliationOutcome == nil else { return }
        if processIdentifier == targetProcessIdentity.processIdentifier,
           self.isCurrentTargetGeneration(targetProcessIdentity)
        {
            self.restoreIfTargetIsFrontmost()
        } else {
            self.observedNonTargetActivation = true
            self.clearRestorationCandidate()
        }
    }

    func handleActivatedApplication(_ application: NSRunningApplication) {
        guard let targetProcessIdentity else {
            self.activationsBeforeTargetResolution.append(ActivationRecord(
                processIdentifier: application.processIdentifier,
                application: application))
            return
        }
        guard self.reconciliationOutcome == nil else { return }

        if application.processIdentifier == targetProcessIdentity.processIdentifier,
           self.isCurrentTargetGeneration(targetProcessIdentity)
        {
            self.restoreIfTargetIsFrontmost()
        } else if !self.restorationDependencies.applicationTerminatedProvider(application) {
            self.observedNonTargetActivation = true
            self.setRestorationCandidate(application)
        }
    }

    func waitForReconciliation() async -> BackgroundRestorationOutcome? {
        guard let reconciliationTask else {
            self.stopObserving()
            return nil
        }
        return await reconciliationTask.value
    }

    var hasActiveReconciliation: Bool {
        self.reconciliationTask != nil && self.reconciliationOutcome == nil
    }

    private func startReconciliationTask(deadline: ContinuousClock.Instant) {
        guard self.reconciliationTask == nil else { return }
        self.reconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return .targetNotFrontmost }
            let now = self.nowProvider()
            if now < deadline {
                await self.sleepHandler(now.duration(to: deadline))
            }
            let outcome = await self.reconcileAtGraceBoundary()
            self.reconciliationOutcome = outcome
            self.stopObserving()
            return outcome
        }
    }

    private func reconcileAtGraceBoundary() async -> BackgroundRestorationOutcome {
        guard let targetProcessIdentity else { return .targetNotFrontmost }
        let targetProcessIdentifier = targetProcessIdentity.processIdentifier
        var fallbackRevision: UInt64?
        let confirmationDeadline = self.nowProvider().advanced(by: self.confirmationTimeout)

        while true {
            let candidate = self.restorationCandidate
            let revision = self.candidateRevision
            let frontmostProcessIdentifier = self.restorationDependencies.frontmostProcessIdentifierProvider()
            if let outcome = self.classifyRestoration(
                candidate: candidate,
                targetProcessIdentity: targetProcessIdentity,
                frontmostProcessIdentifier: frontmostProcessIdentifier)
            {
                return outcome
            }
            if frontmostProcessIdentifier == targetProcessIdentifier,
               self.initialFrontmostProcessIdentity == targetProcessIdentity,
               !self.observedNonTargetActivation
            {
                return .targetWasAlreadyFrontmost
            }

            let now = self.nowProvider()
            guard now < confirmationDeadline else {
                return frontmostProcessIdentifier == targetProcessIdentifier
                    ? .targetStillFrontmost
                    : .targetNotFrontmost
            }

            if frontmostProcessIdentifier == targetProcessIdentifier,
               let candidate,
               candidate.processIdentifier != targetProcessIdentifier,
               !self.restorationDependencies.applicationTerminatedProvider(candidate),
               self.isCurrentTargetGeneration(targetProcessIdentity)
            {
                let accepted = self.restorationDependencies.applicationActivationHandler(candidate)
                await Task.yield()
                guard revision == self.candidateRevision else {
                    continue
                }
                if let outcome = self.classifyRestoration(
                    candidate: candidate,
                    targetProcessIdentity: targetProcessIdentity,
                    frontmostProcessIdentifier: self.restorationDependencies.frontmostProcessIdentifierProvider())
                {
                    return outcome
                }
                if self.restorationDependencies.frontmostProcessIdentifierProvider() == targetProcessIdentifier,
                   self.isCurrentTargetGeneration(targetProcessIdentity),
                   fallbackRevision == revision || !accepted
                {
                    _ = self.restorationDependencies.accessibilityActivationHandler(candidate.processIdentifier)
                    await Task.yield()
                    guard revision == self.candidateRevision else {
                        continue
                    }
                    if let outcome = self.classifyRestoration(
                        candidate: candidate,
                        targetProcessIdentity: targetProcessIdentity,
                        frontmostProcessIdentifier: self.restorationDependencies
                            .frontmostProcessIdentifierProvider())
                    {
                        return outcome
                    }
                }
                fallbackRevision = revision
            }

            let sleepNow = self.nowProvider()
            guard sleepNow < confirmationDeadline else { continue }
            await self.restorationDependencies.confirmationSleepHandler(
                min(.milliseconds(100), sleepNow.duration(to: confirmationDeadline)))
        }
    }

    private func classifyRestoration(
        candidate: NSRunningApplication?,
        targetProcessIdentity: ApplicationProcessIdentity,
        frontmostProcessIdentifier: pid_t?) -> BackgroundRestorationOutcome?
    {
        let targetProcessIdentifier = targetProcessIdentity.processIdentifier
        if frontmostProcessIdentifier == targetProcessIdentifier,
           !self.isCurrentTargetGeneration(targetProcessIdentity)
        {
            return .targetNotFrontmost
        }
        if let candidate,
           candidate.processIdentifier != targetProcessIdentifier,
           !self.restorationDependencies.applicationTerminatedProvider(candidate),
           ApplicationService.isVerifiedApplicationActivation(
               processIdentifier: candidate.processIdentifier,
               isActive: self.restorationDependencies.applicationActiveProvider(candidate),
               frontmostProcessIdentifier: frontmostProcessIdentifier)
        {
            return .candidateConfirmed(candidate.processIdentifier)
        }
        if let frontmostProcessIdentifier, frontmostProcessIdentifier != targetProcessIdentifier {
            return .differentFrontmost(frontmostProcessIdentifier)
        }
        return nil
    }

    private func setRestorationCandidate(_ application: NSRunningApplication) {
        self.candidateRevision &+= 1
        self.restorationCandidate = application
    }

    private func clearRestorationCandidate() {
        self.candidateRevision &+= 1
        self.restorationCandidate = nil
    }

    private static func boundedProtectionDuration(_ duration: Duration) -> Duration {
        max(.zero, min(duration, .seconds(10)))
    }

    private func stopObserving() {
        guard let observer else { return }
        self.notificationCenter.removeObserver(observer)
        self.observer = nil
    }

    private func restorePreviousApplication() {
        guard let restorationCandidate,
              !self.restorationDependencies.applicationTerminatedProvider(restorationCandidate),
              restorationCandidate.processIdentifier != self.targetProcessIdentity?.processIdentifier
        else { return }
        _ = self.restorationDependencies.applicationActivationHandler(restorationCandidate)
    }

    private func restoreIfTargetIsFrontmost() {
        guard let targetProcessIdentity,
              self.reconciliationOutcome == nil,
              self.restorationDependencies.frontmostProcessIdentifierProvider() == targetProcessIdentity
                  .processIdentifier,
                  self.isCurrentTargetGeneration(targetProcessIdentity)
        else { return }
        self.restorePreviousApplication()
    }

    private func isCurrentTargetGeneration(_ processIdentity: ApplicationProcessIdentity) -> Bool {
        self.restorationDependencies.processStartIdentityProvider(processIdentity.processIdentifier) ==
            processIdentity.processStartIdentity
    }
}

@MainActor
private struct SpotlightApplicationSearcher {
    let logger: Logger
    let name: String

    func search() -> URL? {
        self.logger.debug("Using Spotlight to search for: \(self.name)")
        let query = self.makeQuery()
        query.start()
        self.waitForResults(query)
        query.stop()
        self.logger.debug("Spotlight query completed with \(query.resultCount) results")

        guard let match = bestMatch(in: query) else {
            return nil
        }

        let resultMessage = "Spotlight found app: \(match.url.path) (score: \(match.score))"
        self.logger.debug("\(resultMessage)")
        return match.url
    }

    private func makeQuery() -> NSMetadataQuery {
        let query = NSMetadataQuery()
        let predicateFormat =
            "(kMDItemContentType == 'com.apple.application-bundle' || kMDItemContentType == 'com.apple.application')" +
            " && (kMDItemDisplayName CONTAINS[cd] %@ || kMDItemFSName CONTAINS[cd] %@)"
        query.predicate = NSPredicate(format: predicateFormat, self.name, self.name)
        query.searchScopes = [
            NSMetadataQueryIndexedLocalComputerScope,
            NSMetadataQueryIndexedNetworkScope,
        ]
        return query
    }

    private func waitForResults(_ query: NSMetadataQuery) {
        let startTime = Date()
        while query.isGathering, Date().timeIntervalSince(startTime) < 2.0 {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
    }

    private func bestMatch(in query: NSMetadataQuery) -> (url: URL, score: Int)? {
        var bestMatch: (url: URL, score: Int)?
        let searchTerm = self.name.lowercased()

        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else {
                continue
            }

            let appURL = URL(fileURLWithPath: path)
            let displayName = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String) ?? ""
            let fsName = appURL.lastPathComponent

            let spotlightMessage =
                "Spotlight found: \(path), displayName: '\(displayName)', fsName: '\(fsName)'"
            self.logger.debug("\(spotlightMessage)")

            let score = score(for: displayName, fsName: fsName, path: path, searchTerm: searchTerm)
            if score > (bestMatch?.score ?? 0) {
                bestMatch = (appURL, score)
            }

            if score >= 100 {
                break
            }
        }

        return bestMatch
    }

    private func score(
        for displayName: String,
        fsName: String,
        path: String,
        searchTerm: String) -> Int
    {
        var score = 0
        let fsNameNoExt = fsName.hasSuffix(".app") ? String(fsName.dropLast(4)) : fsName
        let displayLower = displayName.lowercased()
        let fsLower = fsNameNoExt.lowercased()

        if displayLower == searchTerm ||
            fsLower == searchTerm ||
            fsName.lowercased() == "\(searchTerm).app"
        {
            score = 100
        } else if displayLower.hasPrefix(searchTerm) || fsLower.hasPrefix(searchTerm) {
            score = 80
        } else if displayLower.contains(searchTerm) || fsLower.contains(searchTerm) {
            score = 50
        }

        if path.hasPrefix("/Applications/") {
            score += 10
        } else if path.hasPrefix("/System/Applications/") {
            score += 5
        }

        if path.contains("/DerivedData/"), path.contains("/Debug/") {
            score += 15
        }

        return score
    }
}
