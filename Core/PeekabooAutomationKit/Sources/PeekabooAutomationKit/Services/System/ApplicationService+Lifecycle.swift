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
        let requestedRunningApplicationIdentity: ApplicationProcessIdentity?
    }

    public func launchApplication(identifier: String) async throws -> ServiceApplicationInfo {
        try await self.launchApplication(request: ApplicationLaunchRequest(applicationIdentifier: identifier))
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

        let requestedRunningApplication = try identifier.flatMap(self.resolveRequestedRunningApplication)
        if requestedRunningApplication != nil, request.createsNewInstance || !request.openURLs.isEmpty {
            throw PeekabooError.invalidInput(
                "A PID launch selector cannot be combined with open targets or --new-instance; " +
                    "use an app path or bundle ID")
        }

        let applicationURL: URL? = if let bundleIdentifier, !bundleIdentifier.isEmpty {
            try self.resolveApplicationURL(bundleIdentifier: bundleIdentifier)
        } else if let requestedRunningApplication {
            requestedRunningApplication.applicationURL
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
            disablesRunningApplicationSubstitution: identifier.map(Self.isExplicitApplicationPath) == true,
            requestedRunningApplicationIdentity: requestedRunningApplication?.processIdentity)
    }

    private func performApplicationLaunch(_ launch: PreparedApplicationLaunch) async throws -> ServiceApplicationInfo {
        let access: DesktopOperationAccess = launch.activates ? .write : .read
        return try await self.operationLaneCoordinator.run(scope: .global, access: access) {
            try await self.performApplicationLaunchWithOwnedLane(launch)
        }
    }

    private func performApplicationLaunchWithOwnedLane(
        _ launch: PreparedApplicationLaunch) async throws -> ServiceApplicationInfo
    {
        if !launch.activates {
            return try await self.performVerifiedBackgroundLaunchNoOp(launch)
        }
        if let requestedIdentity = launch.requestedRunningApplicationIdentity {
            return try await self.activateVerifiedRunningApplication(
                launch,
                requestedIdentity: requestedIdentity)
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = launch.activates
        config.createsNewApplicationInstance = launch.createsNewInstance
        if launch.createsNewInstance {
            config.allowsRunningApplicationSubstitution = false
        }

        // LaunchServices may continue opening an application after its caller is cancelled. Keep
        // ownership of that native operation until it returns a PID so the global desktop lane is
        // not abandoned while an explicitly foreground launch may still complete.
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
        try Task.checkCancellation()

        if !runningApp.isActive, !runningApp.activate(options: []) {
            self.logger.warning("Launch succeeded but failed to activate \(runningApp.localizedName ?? "application")")
        }

        try await self.waitUntilReadyIfNeeded(
            runningApp,
            requested: launch.waitUntilReady,
            expectedIdentity: launchProcessIdentity)
        try await self.waitForWindowIfNeeded(
            runningApp,
            requested: launch.waitForWindow,
            expectedIdentity: launchProcessIdentity)
        try await self.waitUntilActiveIfNeeded(runningApp, requested: true)

        let launchMessage =
            "Successfully launched: \(runningApp.localizedName ?? "Unknown") (PID: \(runningApp.processIdentifier))"
        self.logger.info("\(launchMessage)")
        let application = self.createApplicationInfo(from: runningApp)
        guard application.processIdentity == launchProcessIdentity else {
            throw PeekabooError.commandFailed(
                "Launched application process generation changed before its receipt could be returned")
        }
        return application
    }

    private func performVerifiedBackgroundLaunchNoOp(
        _ launch: PreparedApplicationLaunch) async throws -> ServiceApplicationInfo
    {
        guard launch.openURLs.isEmpty else {
            throw ApplicationLifecycleRefusalError.backgroundLaunch(
                "Background URL or document delivery is refused before dispatch because the target app can activate.")
        }
        guard !launch.createsNewInstance else {
            throw ApplicationLifecycleRefusalError.backgroundLaunch(
                "Background new-instance launch is refused before dispatch because a new app process can activate.")
        }
        guard let applicationURL = launch.applicationURL else {
            throw ApplicationLifecycleRefusalError.backgroundLaunch(
                "Background default-handler launch is refused before dispatch because it can activate an application.")
        }

        let runningApplications = self.runningApplicationsForURLProvider(applicationURL).filter { application in
            !application.isTerminated && Self.application(application, matches: applicationURL)
        }
        let runningApplication = self.selectRunningApplication(
            runningApplications,
            requestedIdentity: launch.requestedRunningApplicationIdentity)
        guard let runningApplication else {
            if launch.requestedRunningApplicationIdentity != nil {
                throw ApplicationLifecycleRefusalError.backgroundLaunch(
                    "The PID-selected application stopped or changed process generation before its no-op " +
                        "receipt was verified.")
            }
            throw ApplicationLifecycleRefusalError.backgroundLaunch(
                "Cold background app launch is refused before dispatch; only an exact already-running no-op is safe.")
        }

        let processIdentity: ApplicationProcessIdentity
        do {
            processIdentity = try self.captureLaunchProcessIdentity(runningApplication)
            try await self.waitUntilReadyIfNeeded(
                runningApplication,
                requested: launch.waitUntilReady,
                expectedIdentity: processIdentity)
            try await self.waitForWindowIfNeeded(
                runningApplication,
                requested: launch.waitForWindow,
                expectedIdentity: processIdentity)
        } catch let error as PeekabooError {
            if case .commandFailed = error {
                throw ApplicationLifecycleRefusalError.backgroundLaunch(
                    "The already-running application changed process generation before its no-op receipt was verified.")
            }
            throw ApplicationLifecycleReadOnlyFailureError(error)
        }

        let application = self.createApplicationInfo(from: runningApplication)
        guard application.processIdentity == processIdentity else {
            throw ApplicationLifecycleRefusalError.backgroundLaunch(
                "The already-running application changed process generation before its no-op receipt was returned.")
        }
        return application
    }

    static func runningApplicationCandidates(
        for applicationURL: URL,
        workspace: NSWorkspace = .shared) -> [NSRunningApplication]
    {
        guard let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier else {
            return workspace.runningApplications
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    }

    private static func application(_ application: NSRunningApplication, matches expectedURL: URL) -> Bool {
        guard let applicationURL = application.bundleURL else { return false }
        return self.canonicalApplicationPath(applicationURL) == self.canonicalApplicationPath(expectedURL)
    }

    private static func canonicalApplicationPath(_ applicationURL: URL) -> String {
        applicationURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func preferredRunningApplication(
        _ applications: [NSRunningApplication]) -> NSRunningApplication?
    {
        applications.min { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive
            }
            return lhs.processIdentifier < rhs.processIdentifier
        }
    }

    func selectRunningApplication(
        _ applications: [NSRunningApplication],
        requestedIdentity: ApplicationProcessIdentity?) -> NSRunningApplication?
    {
        guard let requestedIdentity else {
            return Self.preferredRunningApplication(applications)
        }
        return applications.first { application in
            self.application(application, matches: requestedIdentity)
        }
    }

    private func resolveRequestedRunningApplication(
        _ identifier: String) throws -> (applicationURL: URL, processIdentity: ApplicationProcessIdentity)?
    {
        guard identifier.uppercased().hasPrefix("PID:") else { return nil }
        let pidText = identifier.dropFirst(4)
        guard let processIdentifier = pid_t(pidText), processIdentifier > 0 else {
            throw PeekabooError.invalidInput("Invalid PID launch selector: \(identifier)")
        }
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated,
              let applicationURL = application.bundleURL
        else {
            throw PeekabooError.appNotFound(identifier)
        }
        return try (applicationURL, self.captureLaunchProcessIdentity(application))
    }

    private func application(
        _ application: NSRunningApplication,
        matches expectedIdentity: ApplicationProcessIdentity) -> Bool
    {
        let processIdentifier = application.processIdentifier
        guard processIdentifier == expectedIdentity.processIdentifier,
              !application.isTerminated,
              self.processStartIdentityProvider(processIdentifier) == expectedIdentity.processStartIdentity,
              !application.isTerminated
        else {
            return false
        }
        return self.processStartIdentityProvider(processIdentifier) == expectedIdentity.processStartIdentity
    }

    private func activateVerifiedRunningApplication(
        _ launch: PreparedApplicationLaunch,
        requestedIdentity: ApplicationProcessIdentity) async throws -> ServiceApplicationInfo
    {
        guard let applicationURL = launch.applicationURL,
              let runningApplication = self.runningApplicationsForURLProvider(applicationURL)
                  .first(where: { application in
                      !application.isTerminated &&
                          Self.application(application, matches: applicationURL) &&
                          self.application(application, matches: requestedIdentity)
                  })
        else {
            throw PeekabooError.commandFailed(
                "The PID-selected application stopped or changed process generation before activation")
        }

        try await self.requestVerifiedActivation(
            runningApplication,
            applicationName: runningApplication.localizedName ?? "application")
        guard self.application(runningApplication, matches: requestedIdentity) else {
            throw PeekabooError.commandFailed(
                "The PID-selected application changed process generation during activation")
        }
        try await self.waitUntilReadyIfNeeded(
            runningApplication,
            requested: launch.waitUntilReady,
            expectedIdentity: requestedIdentity)
        try await self.waitForWindowIfNeeded(
            runningApplication,
            requested: launch.waitForWindow,
            expectedIdentity: requestedIdentity)
        let application = self.createApplicationInfo(from: runningApplication)
        guard application.processIdentity == requestedIdentity else {
            throw PeekabooError.commandFailed(
                "The PID-selected application changed process generation before its receipt was returned")
        }
        return application
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
        guard request.launchRequest.activates else {
            throw ApplicationLifecycleRefusalError.backgroundLaunch(
                "Background app relaunch is refused before quit because terminating and launching an app " +
                    "can interrupt the user.")
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
        if identifier.uppercased().hasPrefix("PID:"),
           let processIdentifier = pid_t(identifier.dropFirst(4)),
           processIdentifier > 0,
           let application = NSRunningApplication(processIdentifier: processIdentifier),
           !application.isTerminated,
           let bundleURL = application.bundleURL
        {
            return bundleURL
        }
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

    private func waitUntilReadyIfNeeded(
        _ app: NSRunningApplication,
        requested: Bool,
        expectedIdentity: ApplicationProcessIdentity) async throws
    {
        guard requested else { return }
        let deadline = Date().addingTimeInterval(self.applicationReadinessTimeout)
        while !app.isFinishedLaunching {
            try Task.checkCancellation()
            try self.validateLaunchProcessIdentity(expectedIdentity, application: app)
            guard !app.isTerminated else {
                throw PeekabooError.commandFailed("Application terminated before it finished launching")
            }
            guard Date() < deadline else {
                throw PeekabooError.timeout(
                    "Application did not become ready within \(self.applicationReadinessTimeout) seconds")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try self.validateLaunchProcessIdentity(expectedIdentity, application: app)
    }

    private func waitForWindowIfNeeded(
        _ app: NSRunningApplication,
        requested: Bool,
        expectedIdentity: ApplicationProcessIdentity) async throws
    {
        guard requested else { return }
        let deadline = Date().addingTimeInterval(self.applicationReadinessTimeout)
        while !self.applicationReadinessHandler(app) {
            try Task.checkCancellation()
            try self.validateLaunchProcessIdentity(expectedIdentity, application: app)
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
        try self.validateLaunchProcessIdentity(expectedIdentity, application: app)
    }

    private func validateLaunchProcessIdentity(
        _ expectedIdentity: ApplicationProcessIdentity,
        application: NSRunningApplication) throws
    {
        guard application.processIdentifier == expectedIdentity.processIdentifier,
              !application.isTerminated,
              self.processStartIdentityProvider(application.processIdentifier) ==
              expectedIdentity.processStartIdentity
        else {
            throw PeekabooError.commandFailed("Application changed process generation during launch readiness")
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
        try await self.activateApplication(request: ApplicationActivationRequest(identifier: identifier))
    }

    public func activateApplication(request: ApplicationActivationRequest) async throws {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            self.logger.info("Activating application: \(request.identifier)")
            let app = try await findApplication(identifier: request.identifier)
            guard let resolvedIdentity = app.processIdentity else {
                throw PeekabooError.commandFailed(
                    "Application discovery did not return a stable process generation for activation")
            }
            let expectedIdentity = request.expectedIdentity ?? resolvedIdentity
            guard resolvedIdentity == expectedIdentity else {
                throw PeekabooError.commandFailed(
                    "The activation target changed process generation after initial selection")
            }

            let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier)
            guard let runningApp, self.application(runningApp, matches: expectedIdentity) else {
                throw PeekabooError.operationError(
                    message: "Failed to activate application: target process generation changed before dispatch")
            }

            try await self.requestVerifiedActivation(runningApp, applicationName: app.name)
            guard self.application(runningApp, matches: expectedIdentity) else {
                throw PeekabooError.commandFailed(
                    "The activation target changed process generation before verification completed")
            }
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
