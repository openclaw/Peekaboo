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
        let applicationIdentifier: String?
    }

    public func launchApplication(identifier: String) async throws -> ServiceApplicationInfo {
        try await self.launchApplication(request: ApplicationLaunchRequest(applicationIdentifier: identifier))
    }

    public func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        try await self.launchApplicationResult(request: request).payload
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
            requestedRunningApplicationIdentity: requestedRunningApplication?.processIdentity,
            applicationIdentifier: identifier)
    }

    func performApplicationLaunchWithOutcomeOwnedLane(
        _ launch: PreparedApplicationLaunch) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        self.logger.info("Launching application from the owned desktop lane")
        if !launch.activates {
            let application = try await self.performVerifiedBackgroundLaunchNoOp(launch)
            let boundApplication = try await self.bindSelectorResolution(application, launch: launch)
            return DesktopActionResult(payload: boundApplication, outcome: .confirmedNoChange())
        }
        if let requestedIdentity = launch.requestedRunningApplicationIdentity {
            let activation = try await self.activateVerifiedRunningApplication(
                launch,
                requestedIdentity: requestedIdentity)
            let outcome: DesktopActionOutcome = if let dispatch = activation.dispatch {
                .confirmedChange(delivery: dispatch.delivery, unitCount: dispatch.unitCount)
            } else {
                .confirmedNoChange()
            }
            let boundApplication = try await self.bindSelectorResolution(activation.application, launch: launch)
            return DesktopActionResult(payload: boundApplication, outcome: outcome)
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
        try Self.checkApplicationDispatchCancellation(operation: "Launch application")
        let openTask = Task { @MainActor in
            try Task.checkCancellation()
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
        let runningApp: NSRunningApplication
        do {
            runningApp = try await openTask.value
        } catch {
            throw Self.uncertainDispatchFailure(
                operation: "Launch application",
                mode: .foreground,
                error: error)
        }

        var acceptedNativeDispatchCount = 1
        do {
            let launchProcessIdentity = try self.captureLaunchProcessIdentity(runningApp)
            try Task.checkCancellation()

            if !self.applicationActiveProvider(runningApp) {
                try Task.checkCancellation()
                if self.applicationActivationHandler(runningApp) {
                    acceptedNativeDispatchCount += 1
                } else {
                    self.logger.warning(
                        "Launch succeeded but failed to activate \(runningApp.localizedName ?? "application")")
                }
            }

            try await self.waitUntilReadyIfNeeded(
                runningApp,
                requested: launch.waitUntilReady,
                expectedIdentity: launchProcessIdentity)
            try await self.waitForWindowIfNeeded(
                runningApp,
                requested: launch.waitForWindow,
                expectedIdentity: launchProcessIdentity)
            try await self.waitUntilActiveIfNeeded(
                runningApp,
                requested: true,
                recordAcceptedActivation: {
                    acceptedNativeDispatchCount += 1
                })

            let launchMessage =
                "Successfully launched: \(runningApp.localizedName ?? "Unknown") " +
                "(PID: \(runningApp.processIdentifier))"
            self.logger.info("\(launchMessage)")
            let application = self.createApplicationInfo(from: runningApp)
            guard application.processIdentity == launchProcessIdentity else {
                throw PeekabooError.commandFailed(
                    "Launched application process generation changed before its receipt could be returned")
            }
            let boundApplication = try await self.bindSelectorResolution(application, launch: launch)
            return DesktopActionResult(
                payload: boundApplication,
                outcome: .confirmedChange(
                    delivery: Self.applicationDelivery(mode: .foreground),
                    unitCount: DesktopActionOutcome.DispatchUnitCount(acceptedNativeDispatchCount) ?? .one))
        } catch {
            throw Self.postDispatchFailure(
                operation: "Launch application",
                mode: .foreground,
                error: error,
                unitCount: DesktopActionOutcome.DispatchUnitCount(acceptedNativeDispatchCount) ?? .one)
        }
    }

    private func bindSelectorResolution(
        _ application: ServiceApplicationInfo,
        launch: PreparedApplicationLaunch) async throws -> ServiceApplicationInfo
    {
        guard let identifier = launch.applicationIdentifier,
              let processIdentity = application.processIdentity
        else {
            return application
        }
        let selectorIdentifier: String
        if launch.disablesRunningApplicationSubstitution {
            guard let applicationURL = launch.applicationURL else {
                throw PeekabooError.commandFailed(
                    "The explicit application path did not resolve to an application URL")
            }
            selectorIdentifier = Self.canonicalApplicationPath(applicationURL)
        } else {
            selectorIdentifier = identifier
        }
        let selectedCandidate = ApplicationIdentifierMatcher.Candidate(application)
        let runningCandidates = launch.createsNewInstance
            ? [selectedCandidate]
            : self.applicationSelectorCandidatesProvider()
        let systemResolution = try ApplicationIdentifierMatcher.resolution(
            for: selectorIdentifier,
            in: runningCandidates)
        let resolution: ApplicationIdentifierMatcher.Resolution
        if let systemResolution {
            guard runningCandidates[systemResolution.index].processIdentifier == application.processIdentifier else {
                throw PeekabooError.commandFailed(
                    "The launched application does not match the authoritative selector winner")
            }
            resolution = systemResolution
        } else {
            guard let selectedResolution = try ApplicationIdentifierMatcher.resolution(
                for: selectorIdentifier,
                in: [selectedCandidate])
            else {
                throw PeekabooError.commandFailed(
                    "The launched application does not satisfy its requested selector")
            }
            resolution = selectedResolution
        }
        guard !resolution.hasWinningTie else {
            throw PeekabooError.commandFailed(
                "The launched application selector has more than one authoritative winner")
        }
        return application.withSelectorResolutionProofs([
            resolution.proof(selectedProcessIdentity: processIdentity),
        ])
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
        requestedIdentity: ApplicationProcessIdentity) async throws
        -> (application: ServiceApplicationInfo, dispatch: ApplicationActionDispatch?)
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

        let dispatch = try await self.requestVerifiedActivation(
            runningApplication,
            applicationName: runningApplication.localizedName ?? "application")
        do {
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
            return (application, dispatch)
        } catch {
            guard let dispatch else { throw error }
            throw Self.postDispatchFailure(
                operation: "Activate application for launch",
                dispatch: dispatch,
                error: error)
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
        try await self.relaunchApplicationResult(request: request).payload
    }

    func performApplicationRelaunchWithOutcomeOwnedLane(
        _ request: ApplicationRelaunchRequest,
        terminationTimeoutSeconds: TimeInterval = 5) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
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
        guard preparedLaunch.requestedRunningApplicationIdentity == nil else {
            throw PeekabooError.invalidInput(
                "Atomic relaunch requires a launchable app path or bundle identifier, not an already-running PID")
        }
        guard let expectedTargetIdentity = request.expectedTargetIdentity else {
            throw PeekabooError.commandFailed(
                "Atomic relaunch requires the initially selected process-generation receipt")
        }
        let target = try await self.resolveRelaunchTarget(request.targetIdentifier)
        guard target.processIdentity == expectedTargetIdentity else {
            throw PeekabooError.commandFailed(
                "The relaunch target changed process generation after initial selection")
        }
        try Self.validateRelaunchLaunchOwnership(preparedLaunch, target: target)
        if target.processIdentifier == getpid() {
            throw PeekabooError.serviceUnavailable("A runtime host cannot relaunch itself")
        }
        let canonicalTargetIdentifier = "PID:\(target.processIdentifier)"
        let quitRequest = ApplicationQuitRequest(
            identifier: canonicalTargetIdentifier,
            force: request.force,
            expectedIdentity: expectedTargetIdentity)
        try Self.checkApplicationDispatchCancellation(operation: "Application relaunch")

        var quitCompleted = false
        var relaunchSequence = DesktopActionSequenceAccumulator()
        do {
            try self.validateApplicationQuitIdentity(
                expectedTargetIdentity,
                resolvedApplication: target)
            let quitAttempt: ApplicationQuitAttempt
            do {
                quitAttempt = try await self.quitRelaunchTarget(
                    quitRequest,
                    resolvedApplication: target,
                    expectedIdentity: expectedTargetIdentity)
            } catch {
                throw Self.uncertainDispatchFailure(
                    operation: "Quit application for relaunch",
                    mode: .background,
                    error: error)
            }
            guard quitAttempt.requestAccepted else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "The quit step of relaunch was not accepted for \(target.name).",
                    hint: "Refresh the application inventory before retrying.")
            }
            guard quitAttempt.terminated else {
                throw DesktopActionFailure.suspectedNoop(
                    delivery: Self.applicationDelivery(mode: .background),
                    unitCount: .one,
                    message: "The quit step of relaunch did not terminate the application.",
                    hint: "Refresh the application inventory before retrying.")
            }
            let terminationDeadline = Date().addingTimeInterval(terminationTimeoutSeconds)
            do {
                while try await self.isRelaunchTargetRunning(identifier: canonicalTargetIdentifier) {
                    guard Date() < terminationDeadline else {
                        throw DesktopActionFailure.suspectedNoop(
                            delivery: Self.applicationDelivery(mode: .background),
                            unitCount: .one,
                            message: "The quit step of relaunch was accepted, but the application remained alive.",
                            hint: "Refresh the application inventory before retrying.")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                throw Self.postDispatchFailure(
                    operation: "Verify application termination for relaunch",
                    mode: .background,
                    error: error)
            }
            quitCompleted = true
            relaunchSequence.record(.outcome(.confirmedChange(
                delivery: Self.applicationDelivery(mode: .background),
                unitCount: .one)))

            if request.waitSeconds > 0 {
                try await Task.sleep(for: .seconds(request.waitSeconds))
            }
            let launchResult = try await self.performApplicationLaunchWithOutcomeOwnedLane(preparedLaunch)
            guard let launchOutcome = launchResult.outcome else {
                return DesktopActionResult(payload: launchResult.payload, outcome: nil)
            }
            relaunchSequence.record(.outcome(launchOutcome))
            return DesktopActionResult(
                payload: launchResult.payload,
                outcome: relaunchSequence.successResolution().outcome)
        } catch {
            guard quitCompleted else { throw error }
            let quitDelivery = Self.applicationDelivery(mode: .background)
            if let failure = error as? DesktopActionFailure {
                throw relaunchSequence.failure(
                    combining: failure,
                    message: "The application quit successfully, but relaunch did not complete.",
                    hint: "Recover by observing whether launch completed before retrying.",
                    causeDescription: String(describing: error))
            }
            throw DesktopActionFailure.partial(
                delivery: quitDelivery,
                unitCount: .one,
                message: "The application quit successfully, but relaunch did not complete.",
                hint: "Recover by launching the application again after confirming it remains stopped.",
                causeDescription: String(describing: error))
        }
    }

    private func resolveRelaunchTarget(_ identifier: String) async throws -> ServiceApplicationInfo {
        if let relaunchTargetResolver = self.relaunchTargetResolver {
            return try await relaunchTargetResolver(identifier)
        }
        return try await self.findApplication(identifier: identifier)
    }

    private static func validateRelaunchLaunchOwnership(
        _ launch: PreparedApplicationLaunch,
        target: ServiceApplicationInfo) throws
    {
        guard let launchURL = launch.applicationURL else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Atomic relaunch requires an application bundle to launch after quitting the target.",
                hint: "Relaunch the selected application by its bundle identifier or exact application path.")
        }
        guard let targetBundlePath = target.bundlePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !targetBundlePath.isEmpty
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Atomic relaunch could not prove the selected application's bundle path.",
                hint: "Refresh the application inventory before retrying.")
        }
        let targetURL = URL(fileURLWithPath: NSString(string: targetBundlePath).expandingTildeInPath)
        guard self.canonicalApplicationPath(launchURL) == self.canonicalApplicationPath(targetURL) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Atomic relaunch requires the quit target and launch request to name the same application.",
                hint: "Use the selected application's bundle identifier or exact application path.")
        }
    }

    private func quitRelaunchTarget(
        _ request: ApplicationQuitRequest,
        resolvedApplication: ServiceApplicationInfo,
        expectedIdentity: ApplicationProcessIdentity) async throws -> ApplicationQuitAttempt
    {
        if let relaunchQuitHandler = self.relaunchQuitHandler {
            return try await relaunchQuitHandler(request)
        }
        do {
            return try await self.quitApplicationWithOwnedLane(
                request: request,
                resolvedApplication: resolvedApplication,
                expectedIdentity: expectedIdentity)
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch let error as PeekabooError {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The relaunch target disappeared or changed process generation before quit dispatch.",
                hint: "Refresh the application inventory before retrying.",
                causeDescription: String(describing: error))
        } catch {
            throw error
        }
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

    private func waitUntilActiveIfNeeded(
        _ app: NSRunningApplication,
        requested: Bool,
        recordAcceptedActivation: () -> Void) async throws
    {
        guard requested else { return }
        let deadline = Date().addingTimeInterval(2)
        while !self.applicationActiveProvider(app), Date() < deadline {
            try Task.checkCancellation()
            if self.applicationActivationHandler(app) {
                recordAcceptedActivation()
            }
            try await self.applicationActivationSleepHandler(.milliseconds(50))
        }
        guard self.applicationActiveProvider(app) else {
            throw PeekabooError.timeout(
                "Application did not become active within 2 seconds: \(app.localizedName ?? "unknown")")
        }
    }

    public func activateApplication(identifier: String) async throws {
        try await self.activateApplication(request: ApplicationActivationRequest(identifier: identifier))
    }

    public func activateApplication(request: ApplicationActivationRequest) async throws {
        _ = try await self.activateApplicationResult(request: request)
    }

    func performApplicationActivationWithOwnedLane(
        _ request: ApplicationActivationRequest) async throws -> ApplicationActionDispatch?
    {
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

        let dispatch = try await self.requestVerifiedActivation(runningApp, applicationName: app.name)
        guard self.application(runningApp, matches: expectedIdentity) else {
            let error = PeekabooError.commandFailed(
                "The activation target changed process generation before verification completed")
            guard let dispatch else { throw error }
            throw Self.postDispatchFailure(
                operation: "Activate application",
                dispatch: dispatch,
                error: error)
        }
        self.logger.info("Successfully activated and verified frontmost: \(app.name)")
        return dispatch
    }

    private func requestVerifiedActivation(
        _ application: NSRunningApplication,
        applicationName: String) async throws -> ApplicationActionDispatch?
    {
        let processIdentifier = application.processIdentifier
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: self.applicationActivationTimeout)
        var shouldUseAccessibilityFallback = false
        var nativeRequestAccepted = false
        var accessibilityRequestAccepted = false
        var acceptedRequestCount = 0
        var lastAcceptedMechanism: DesktopActionOutcome.Delivery.Mechanism?
        var hasMixedAcceptedMechanisms = false

        func dispatchReceipt() -> ApplicationActionDispatch? {
            ApplicationActionDispatch(
                mechanism: lastAcceptedMechanism,
                mode: .foreground,
                acceptedRequestCount: hasMixedAcceptedMechanisms ? nil : acceptedRequestCount)
        }

        func recordAcceptedRequest(_ mechanism: DesktopActionOutcome.Delivery.Mechanism) {
            if let lastAcceptedMechanism, lastAcceptedMechanism != mechanism {
                hasMixedAcceptedMechanisms = true
            }
            acceptedRequestCount += 1
            lastAcceptedMechanism = mechanism
        }

        do {
            repeat {
                try Task.checkCancellation()
                guard !application.isTerminated else {
                    throw PeekabooError.operationError(
                        message: "Failed to activate \(applicationName): application terminated during activation")
                }
                if self.isVerifiedActive(application, processIdentifier: processIdentifier) {
                    return dispatchReceipt()
                }

                try Task.checkCancellation()
                let accepted = self.applicationActivationHandler(application)
                nativeRequestAccepted = nativeRequestAccepted || accepted
                if accepted {
                    recordAcceptedRequest(.nativeFramework)
                }
                if shouldUseAccessibilityFallback || !accepted {
                    try Task.checkCancellation()
                    let accessibilityAccepted = self.applicationAccessibilityActivationHandler(processIdentifier)
                    accessibilityRequestAccepted = accessibilityAccepted || accessibilityRequestAccepted
                    if accessibilityAccepted {
                        recordAcceptedRequest(.accessibilityAction)
                    }
                }

                if self.isVerifiedActive(application, processIdentifier: processIdentifier) {
                    return dispatchReceipt()
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
            guard let dispatch = dispatchReceipt() else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "The activation request was not accepted for \(applicationName).",
                    hint: "Refresh the application inventory before retrying.",
                    causeDescription: diagnostic)
            }
            throw DesktopActionFailure.suspectedNoop(
                delivery: dispatch.delivery,
                unitCount: dispatch.unitCount,
                message: "Application did not become active and frontmost: \(applicationName).",
                hint: "Refresh the frontmost application and window inventory before retrying.",
                causeDescription: diagnostic)
        } catch {
            guard let dispatch = dispatchReceipt() else { throw error }
            throw Self.postDispatchFailure(
                operation: "Activate application",
                dispatch: dispatch,
                error: error)
        }
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
        try await self.legacyQuitApplication(request: ApplicationQuitRequest(
            identifier: identifier,
            force: force))
    }

    public func quitApplication(request: ApplicationQuitRequest) async throws -> Bool {
        try await self.legacyQuitApplication(request: request)
    }

    private func legacyQuitApplication(request: ApplicationQuitRequest) async throws -> Bool {
        do {
            return try await self.quitApplicationResult(request: request).payload
        } catch let failure as DesktopActionFailure where Self.isRejectedLegacyQuitRequest(failure) {
            // v4.1.0 exposed a rejected native terminate request as `false`. Preserve that
            // contract without weakening canonical failures for the result API.
            return false
        }
    }

    private static func isRejectedLegacyQuitRequest(_ failure: DesktopActionFailure) -> Bool {
        failure.outcome.route == .local &&
            failure.outcome.state == .refused &&
            failure.outcome.refusalReason == .targetUnavailable &&
            failure.outcome.dispatchState == .none
    }

    func quitApplicationWithOwnedLane(
        request: ApplicationQuitRequest,
        resolvedApplication app: ServiceApplicationInfo,
        expectedIdentity: ApplicationProcessIdentity) async throws -> ApplicationQuitAttempt
    {
        try self.validateApplicationQuitIdentity(expectedIdentity, resolvedApplication: app)

        // Create NSRunningApplication
        let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier)
        guard let runningApp else {
            throw PeekabooError.appNotFound(request.identifier)
        }

        self.logger.debug("Sending \(request.force ? "force terminate" : "terminate") signal to \(app.name)")
        try self.validateApplicationQuitIdentity(expectedIdentity, resolvedApplication: app)
        try Self.checkApplicationDispatchCancellation(operation: "Quit application")
        let success = self.applicationQuitHandler(runningApp, request.force)

        guard success else {
            self.logger.error("Failed to quit: \(app.name)")
            return ApplicationQuitAttempt(requestAccepted: false, terminated: false)
        }

        let terminated: Bool
        do {
            terminated = try await waitForApplicationTermination(timeoutSeconds: self.applicationQuitTimeout) {
                runningApp.isTerminated || NSRunningApplication(processIdentifier: app.processIdentifier) == nil
            }
        } catch {
            throw Self.postDispatchFailure(
                operation: "Quit application",
                mode: .background,
                error: error)
        }
        if terminated {
            self.logger.info("Successfully quit and verified termination: \(app.name)")
        } else {
            let message = "Quit request was accepted but the process remained alive: \(app.name) " +
                "(PID: \(app.processIdentifier))"
            self.logger.error("\(message, privacy: .public)")
        }
        return ApplicationQuitAttempt(requestAccepted: true, terminated: terminated)
    }

    func validateApplicationQuitIdentity(
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
        _ = try await self.hideApplicationResult(identifier: identifier)
    }

    public func unhideApplication(identifier: String) async throws {
        _ = try await self.unhideApplicationResult(identifier: identifier)
    }

    func requestApplicationVisibility(
        _ application: NSRunningApplication,
        hidden: Bool) throws -> ApplicationVisibilityAttempt
    {
        if let applicationVisibilityHandler = self.applicationVisibilityHandler {
            try Self.checkApplicationDispatchCancellation(
                operation: hidden ? "Hide application" : "Unhide application")
            let accepted = try applicationVisibilityHandler(application, hidden)
            guard accepted else { return .rejected }
            return .accepted(ApplicationActionDispatch(
                delivery: DesktopActionOutcome.Delivery(
                    mechanism: .nativeFramework,
                    mode: .background),
                unitCount: .one))
        }
        if !hidden {
            try Self.checkApplicationDispatchCancellation(operation: "Unhide application")
            guard self.applicationNativeVisibilityHandler(application, false) else { return .rejected }
            return .accepted(ApplicationActionDispatch(
                delivery: DesktopActionOutcome.Delivery(
                    mechanism: .nativeFramework,
                    mode: .background),
                unitCount: .one))
        }

        do {
            try Self.checkApplicationDispatchCancellation(operation: "Hide application")
            try self.applicationAccessibilityHideHandler(application)
            return .accepted(ApplicationActionDispatch(
                delivery: DesktopActionOutcome.Delivery(
                    mechanism: .accessibilityAction,
                    mode: .background),
                unitCount: .one))
        } catch let failure as DesktopActionFailure {
            guard failure.outcome.state == .refused,
                  failure.outcome.dispatchState == .none,
                  failure.outcome.retrySafety == .safe,
                  let refusalReason = failure.outcome.refusalReason,
                  [.operationUnsupported, .permissionDenied].contains(refusalReason)
            else {
                throw failure
            }
            // The typed AX refusal above proves zero dispatch. Cancellation before the native
            // fallback therefore remains a pre-dispatch refusal instead of inventing an AX unit.
            try Self.checkApplicationDispatchCancellation(operation: "Hide application fallback")
            guard self.applicationNativeVisibilityHandler(application, true) else {
                return .rejected
            }
            return .accepted(ApplicationActionDispatch(
                delivery: DesktopActionOutcome.Delivery(
                    mechanism: .nativeFramework,
                    mode: .background),
                unitCount: .one))
        } catch {
            _ = error.asPeekabooError(context: "AX hide action failed")
            // A generic AX error does not prove that dispatch was rejected. Replaying the hide
            // through AppKit could therefore toggle or duplicate a mutation that already happened.
            return .mayHaveDispatched(
                delivery: DesktopActionOutcome.Delivery(
                    mechanism: .accessibilityAction,
                    mode: .background),
                unitCount: .one,
                causeDescription: String(describing: error))
        }
    }

    public func hideOtherApplications(identifier: String) async throws {
        _ = try await self.hideOtherApplicationsActionResult(identifier: identifier)
    }

    public func showAllApplications() async throws {
        _ = try await self.showAllApplicationsActionResult()
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
